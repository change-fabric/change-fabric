# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'
require_relative 'prototype_capture'
require_relative 'prototype_imagegen'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_captions'
require_relative 'walkthrough_elevenlabs'
require_relative 'walkthrough_env'
require_relative 'walkthrough_ffmpeg'
require_relative 'walkthrough_manifest'
require_relative 'walkthrough_storyboard'

# Orchestrates one walkthrough render: validate, estimate, generate missing
# narration, images, frames, and music, rebuild the manifest, then assemble
# from the cache with two FFmpeg passes in FFMPEG_IMAGE. Assembly reads the
# cache only; a missing entry there is a hard error. Every provider and the
# docker runner are injectable so the flow tests without network or docker.
module WalkthroughRender
  WORK = '/work'
  CURSOR_PNG = File.join(__dir__, 'vendor', 'walkthrough', 'cursor.png')

  class MissingCacheError < StandardError; end
  class FfmpegError < StandardError; end

  DEFAULT_PROVIDERS = {
    tts: ->(**kw) { WalkthroughElevenlabs.tts(**kw) },
    music: ->(**kw) { WalkthroughElevenlabs.music(**kw) },
    image: ->(**kw) { PrototypeImagegen.generate(**kw) },
    browser: ->(&blk) { ChangeDocker.with_browserless(network: nil, &blk) },
    capture: ->(**kw) { PrototypeCapture.capture(**kw) },
    docker: ->(argv) { Open3.capture2e(*argv) }
  }.freeze

  class Run
    attr_reader :root, :board, :log

    def initialize(root, scene: nil, final: false, providers: {}, out: $stdout)
      @root = File.expand_path(root)
      @only = scene
      @final = final
      @p = DEFAULT_PROVIDERS.merge(providers)
      @out = out
      @cache = File.join(@root, '.cache')
      @board_path = File.join(@root, 'storyboard.json')
      @board = WalkthroughStoryboard.load(@board_path)
      @log = []
    end

    def say(line)
      @log << line
      @out.puts(line)
    end

    def scenes = WalkthroughStoryboard.scenes(@board)

    def targeted?(scene) = @only.nil? || scene['id'] == @only

    def voice = @board['voice'] || {}

    # -- estimate ---------------------------------------------------------

    def audio_cached?(scene)
      File.file?(WalkthroughCache.path(@cache, :audio, WalkthroughStoryboard.audio_key(@board, scene), 'mp3'))
    end

    def narrated?(scene) = !scene.dig('narration', 'text').to_s.strip.empty?

    def image_quality(img) = @final ? PrototypeImagegen::QUALITY_FINAL : (img['quality'] || PrototypeImagegen::QUALITY_DRAFT)

    def image_requests(scene)
      Array(scene['images']).map do |img|
        { prompt: img['prompt'].to_s, size: img['size'] || '1024x1024', quality: image_quality(img),
          refs: Array(img['refs']).map { |r| File.join(@root, r) } }
      end
    end

    def image_cached?(req)
      key = PrototypeImagegen.asset_key(prompt: req[:prompt], size: req[:size], quality: req[:quality], refs: req[:refs])
      File.file?(WalkthroughCache.path(@cache, :images, key, 'png'))
    end

    def music_block = { prompt: @board.dig('music', 'prompt'), composition_plan: @board.dig('music', 'composition_plan'),
                        model: @board.dig('music', 'model') }

    def music_path(total_ms)
      len = WalkthroughElevenlabs.clamp_music_ms(total_ms)
      WalkthroughCache.path(@cache, :music, WalkthroughElevenlabs.music_key(music_block, len), 'mp3')
    end

    def estimate
      todo = scenes.select { |s| targeted?(s) }
      chars = todo.select { |s| narrated?(s) && !audio_cached?(s) }.sum { |s| s.dig('narration', 'text').length }
      total = WalkthroughStoryboard.timeline(@board)['total_ms']
      music_ms = @board['music'] && !File.file?(music_path(total)) ? WalkthroughElevenlabs.clamp_music_ms(total) : 0
      images = todo.flat_map { |s| image_requests(s) }.reject { |r| image_cached?(r) }
      est = { audio: WalkthroughElevenlabs.estimate(chars: chars, music_ms: music_ms, model: voice['model']),
              images: PrototypeImagegen.estimate(images) }
      say(WalkthroughElevenlabs.format_estimate(est[:audio]))
      say("OpenAI estimate: #{est[:images][:line]}")
      est
    end

    # -- generation -------------------------------------------------------

    def generate_audio
      scenes.each do |scene|
        next unless narrated?(scene)

        key = WalkthroughStoryboard.audio_key(@board, scene)
        align = WalkthroughCache.path(@cache, :audio, key, 'alignment.json')
        if audio_cached?(scene) || !targeted?(scene)
          scene['narration']['measured_ms'] = WalkthroughElevenlabs.measured_from(align) if File.file?(align)
          next
        end
        say("#{scene['id']}: narrating")
        res = @p[:tts].call(text: scene['narration']['text'], voice_id: voice['voice_id'], model: voice['model'],
                            output_format: voice['output_format'], settings: voice['settings'] || {}, cache_root: @cache)
        scene['narration']['measured_ms'] = res[:measured_ms]
      end
    end

    def generate_images
      attempts = PrototypeImagegen::Attempts.new
      scenes.select { |s| targeted?(s) }.each do |scene|
        image_requests(scene).reject { |r| image_cached?(r) }.each do |req|
          say("#{scene['id']}: image")
          @p[:image].call(**req, cache_root: @cache, screen: scene['id'], attempts: attempts)
        end
      end
    end

    # Captures in storyboard order, so a from_scene dependency (always a
    # lower order) is captured before the scenes that start from it. The
    # browser container opens only when at least one scene needs frames.
    def capture_frames
      return unless capture_needed?

      with_session { |session| capture_all(session) }
    end

    def capture_needed?
      memo = {}
      scenes.any? do |scene|
        next false unless targeted?(scene)

        prep = PrototypeCapture.prepare(@board, scene, @root, memo)
        !File.file?(File.join(prep[:out_dir], 'end-state.json'))
      rescue ArgumentError
        true
      end
    end

    def with_session(&blk) = @p[:browser].call(&blk)

    def capture_all(session)
      memo = {}
      scenes.each do |scene|
        prep = PrototypeCapture.prepare(@board, scene, @root, memo)
        next if File.file?(File.join(prep[:out_dir], 'end-state.json')) || !targeted?(scene)

        duration = PrototypeCapture.scene_duration(scene)
        say("#{scene['id']}: capturing #{PrototypeCapture.frame_count(duration, fps)} frames")
        @p[:capture].call(session: session, html: PrototypeCapture.inline_screen(prep[:html_path]),
                          interactions: scene['interactions'] || [], duration_ms: duration, out_dir: prep[:out_dir],
                          state: prep[:state], prng_seed: prep[:prng_seed], viewport: @board['viewport'], fps: fps,
                          label: scene['id'])
      end
    end

    def fps = @board['fps'] || PrototypeCapture::FPS

    def generate_music(total_ms)
      return unless @board['music']
      return if File.file?(music_path(total_ms))

      say('music: composing')
      @p[:music].call(**music_block, length_ms: WalkthroughElevenlabs.clamp_music_ms(total_ms), cache_root: @cache)
    end

    # -- assembly (cache only) -----------------------------------------------

    def container(path) = File.join(WORK, path.delete_prefix("#{@root}/"))

    def require_file!(path, what)
      raise MissingCacheError, "#{what} missing from cache: #{path.delete_prefix("#{@root}/")}" unless File.file?(path)

      path
    end

    # Resolves every cached input the render needs, raising on any gap.
    def assembly_inputs(manifest)
      by_id = scenes.to_h { |s| [ s['id'], s ] }
      manifest['scenes'].map do |entry|
        scene = by_id.fetch(entry['id'])
        key = entry['frames_key'] or raise MissingCacheError, "#{entry['id']}: frames not captured"
        dir = File.join(@cache, 'frames', key)
        require_file!(File.join(dir, '000001.png'), "#{entry['id']} frames")
        cursor = JSON.parse(File.read(require_file!(File.join(dir, 'cursor.json'), "#{entry['id']} cursor path")))
        audio = align = nil
        if narrated?(scene)
          audio = require_file!(WalkthroughCache.path(@cache, :audio, entry['audio_key'], 'mp3'), "#{entry['id']} narration")
          align = JSON.parse(File.read(require_file!(WalkthroughCache.path(@cache, :audio, entry['audio_key'], 'alignment.json'),
                                                     "#{entry['id']} alignment")))
        end
        { entry: entry, scene: scene, dir: dir, cursor: cursor, audio: audio, alignment: align,
          offset_ms: (entry['start_frame'] * 1000.0 / fps).round }
      end
    end

    def captions(inputs)
      words = inputs.select { |i| i[:alignment] }.flat_map do |i|
        WalkthroughCaptions.word_spans(i[:alignment], offset_ms: i[:offset_ms])
      end
      WalkthroughCaptions.srt(WalkthroughCaptions.cues(words))
    end

    def duck_spans(inputs)
      WalkthroughCaptions.duck_spans(inputs.select { |i| i[:alignment] }.map do |i|
        { offset_ms: i[:offset_ms], alignment: i[:alignment], duck_db: i[:scene].dig('timing', 'music_duck_db') || -12 }
      end)
    end

    def render_dir(manifest) = File.join(@cache, 'render', manifest['manifest_hash'])

    def plan(manifest, inputs)
      dir = render_dir(manifest)
      viewport = @board['viewport'] || PrototypeCapture::DEFAULT_VIEWPORT
      total = manifest.dig('timeline', 'total_ms')
      music = nil
      if @board['music']
        music = { path: container(require_file!(music_path(total), 'music')), gain_db: @board.dig('music', 'gain_db') || -18 }
      end
      { fps: fps, width: viewport['w'], height: viewport['h'], total_ms: total,
        cursor_png: container(File.join(dir, 'cursor.png')), srt: container(File.join(dir, 'captions.srt')),
        output: container(File.join(dir, 'walkthrough.mp4')), music: music, duck_spans: duck_spans(inputs),
        scenes: inputs.map do |i|
          { id: i[:entry]['id'], frames_dir: container(i[:dir]), frames: i[:entry]['frames'],
            start_frame: i[:entry]['start_frame'], transition: i[:scene].dig('timing', 'transition') || { 'type' => 'cut', 'ms' => 0 },
            cursor: i[:cursor], hero_still: i[:scene]['hero_still'] == true, audio: i[:audio] && container(i[:audio]),
            offset_ms: i[:offset_ms] }
        end }
    end

    def docker_argv(args)
      ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args,
                               mounts: { @root => WORK }, workdir: WORK)
    end

    def ffmpeg!(args, label)
      out, status = @p[:docker].call(docker_argv(args))
      raise FfmpegError, "ffmpeg #{label} failed:\n#{out.to_s.lines.last(20).join}" unless status.success?

      out
    end

    def preflight!
      out = ffmpeg!([ '-hide_banner', '-buildconf' ], 'buildconf')
      missing = %w[libass libx264].reject { |lib| out.include?("--enable-#{lib}") }
      raise FfmpegError, "#{ChangeDocker::FFMPEG_IMAGE} lacks #{missing.join(' and ')}" unless missing.empty?
    end

    # Returns the mp4 path; a render already cached for this manifest hash
    # runs no docker at all.
    def assemble(manifest)
      dir = render_dir(manifest)
      mp4 = File.join(dir, 'walkthrough.mp4')
      return mp4 if File.file?(mp4)

      inputs = assembly_inputs(manifest)
      plan = plan(manifest, inputs)
      FileUtils.mkdir_p(dir)
      FileUtils.cp(CURSOR_PNG, File.join(dir, 'cursor.png'))
      File.write(File.join(dir, 'captions.srt'), captions(inputs))
      WalkthroughFfmpeg.sendcmd_files(plan).each { |path, body| File.write(File.join(@root, path.delete_prefix("#{WORK}/")), body) }
      preflight!
      measured = WalkthroughFfmpeg.parse_loudnorm(ffmpeg!(WalkthroughFfmpeg.pass1(plan), 'pass 1'))
      ffmpeg!(WalkthroughFfmpeg.pass2(plan, measured), 'pass 2')
      require_file!(mp4, 'rendered mp4')
    end

    # -- driver -------------------------------------------------------------

    def call(estimate_only: false)
      WalkthroughEnv.load_secrets
      WalkthroughStoryboard.validate!(@board, root: @root)
      WalkthroughCache.ensure_gitignore(@root)
      estimate
      return nil if estimate_only

      generate_audio
      generate_images
      capture_frames
      keys = WalkthroughStoryboard.recompute_keys(@board, @root)
      WalkthroughStoryboard.fix_keys(@board, @root, keys)
      manifest = WalkthroughManifest.build(@board, @root, keys: keys)
      generate_music(manifest.dig('timeline', 'total_ms'))
      File.write(@board_path, "#{JSON.pretty_generate(@board)}\n")
      WalkthroughManifest.write(manifest, @root)
      mp4 = assemble(manifest)
      say("manifest #{manifest['manifest_hash']}")
      say("mp4 #{Digest::SHA256.file(mp4).hexdigest} #{mp4}")
      { manifest: manifest, mp4: mp4 }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = 'usage: walkthrough_render.rb walkthrough/<slug> [--scene <id>] [--draft|--final] [--estimate-only]'
  dir = ARGV.first
  abort(usage) if dir.nil? || dir.start_with?('--')
  scene = ARGV.include?('--scene') ? (ARGV[ARGV.index('--scene') + 1] || abort(usage)) : nil
  abort('--draft and --final are exclusive') if ARGV.include?('--draft') && ARGV.include?('--final')
  WalkthroughRender::Run.new(dir, scene: scene, final: ARGV.include?('--final')).call(estimate_only: ARGV.include?('--estimate-only'))
end
