# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'shellwords'
require 'open3'
require_relative 'b_roll'
require_relative 'change_docker'
require_relative 'prototype_capture'
require_relative 'prototype_imagegen'
require_relative 'prototype_ux_lint'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_captions'
require_relative 'elevenlabs'
require_relative 'ffmpeg_watchdog'
require_relative 'walkthrough_env'
require_relative 'walkthrough_ffmpeg'
require_relative 'walkthrough_housekeeping'
require_relative 'walkthrough_live'
require_relative 'walkthrough_manifest'
require_relative 'walkthrough_roast'
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
    tts: ->(**kw) { ElevenLabs.tts(**kw) },
    music: ->(**kw) { ElevenLabs.music(**kw) },
    image: ->(**kw) { PrototypeImagegen.generate(**kw) },
    broll: ->(**kw) { BRoll.generate_or_fallback(**kw) },
    browser: ->(&blk) { ChangeDocker.with_browserless(network: nil, &blk) },
    capture: ->(**kw) { PrototypeCapture.capture(**kw) },
    lint: ->(**kw) { PrototypeCapture.lint_only(**kw) },
    live_browser: lambda { |opts, &blk|
      ChangeDocker.with_browserless(network: opts['network'], add_hosts: opts['add_hosts'] || [], &blk)
    },
    live_login: ->(**kw) { WalkthroughLive.login(**kw) },
    live_capture: ->(**kw) { WalkthroughLive.capture(**kw) },
    roast: ->(**kw) { Roast.critique(**kw) },
    docker: ->(argv) { Open3.capture2e(*argv) },
    # Pass 2 runs under a watchdog that kills it once its output clock passes
    # the timeline (FfmpegWatchdog); same [output, status] contract as docker.
    ffmpeg_watch: ->(argv, **kw) { FfmpegWatchdog.run(argv, **kw) }
  }.freeze
  # Set to write pass 2's argv, filter graph and the loudnorm measurement
  # into the render dir, for diagnosing a failed assembly.
  DEBUG_ENV = 'CF_WALKTHROUGH_DEBUG'

  class Run
    attr_reader :root

    # rubocop:disable Metrics/ParameterLists
    def initialize(root, scene: nil, final: false, providers: {}, out: $stdout, board: nil, max_usd: BRoll::DEFAULT_CEILING_USD,
                   burn_captions: false, gates: {}, recapture: false)
      # rubocop:enable Metrics/ParameterLists
      @root = File.expand_path(root)
      @gates = { allow_ux: false, allow_roast: false, roast: true, roast_max_usd: WalkthroughRoast::DEFAULT_CEILING_USD }.merge(gates)
      @only = scene
      @recapture = recapture
      @personas = {}
      @final = final
      @burn_captions = burn_captions
      @p = DEFAULT_PROVIDERS.merge(providers)
      # An injected docker runner also runs pass 2 unless a watcher is given.
      @p[:ffmpeg_watch] = ->(argv, **) { @p[:docker].call(argv) } if providers.key?(:docker) && !providers.key?(:ffmpeg_watch)
      @out = out
      @cache = File.join(@root, '.cache')
      @board_path = File.join(@root, 'storyboard.json')
      @board = board || WalkthroughStoryboard.load(@board_path)
      @budget = BRoll::Budget.new(max_usd)
    end

    # Every progress line passes through the env-value mask.
    def say(line)
      @out.puts(secrets.mask(line))
    end

    def secrets = @secrets ||= WalkthroughLive::Secrets.new(WalkthroughLive.env_names(@board))

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
        { prompt: img['prompt'].to_s, size: img['size'] || WalkthroughStoryboard::DEFAULT_IMAGE_SIZE,
          quality: image_quality(img), model: img['model'] || PrototypeImagegen::MODEL,
          refs: Array(img['refs']).map { |r| File.join(@root, r) } }
      end
    end

    def image_cached?(req)
      key = PrototypeImagegen.asset_key(**req.slice(:prompt, :size, :quality, :refs, :model))
      File.file?(WalkthroughCache.path(@cache, :images, key, 'png'))
    end

    def broll?(scene) = WalkthroughStoryboard.broll?(scene)

    def broll_args(scene)
      spec = WalkthroughStoryboard.broll_spec(scene)
      { source_image: File.join(@root, spec['source_image']), prompt: spec['prompt'].to_s, seconds: spec['seconds'], model: spec['model'] }
    end

    def broll_cached?(scene)
      BRoll.mode_for(@cache, 'static', **broll_args(scene)) == 'generated'
    end

    def music_block = { prompt: @board.dig('music', 'prompt'), composition_plan: @board.dig('music', 'composition_plan'),
                        model: @board.dig('music', 'model') }

    def music_path(total_ms)
      len = ElevenLabs.clamp_music_ms(total_ms)
      WalkthroughCache.path(@cache, :music, ElevenLabs.music_key(music_block, len), 'mp3')
    end

    def estimate
      todo = scenes.select { |s| targeted?(s) }
      chars = todo.select { |s| narrated?(s) && !audio_cached?(s) }.sum { |s| s.dig('narration', 'text').length }
      total = WalkthroughStoryboard.timeline(@board)['total_ms']
      music_ms = @board['music'] && !File.file?(music_path(total)) ? ElevenLabs.clamp_music_ms(total) : 0
      images = todo.flat_map { |s| image_requests(s) }.reject { |r| image_cached?(r) }
      clips = todo.select { |s| broll?(s) && !broll_cached?(s) }.map { |s| { seconds: WalkthroughStoryboard.broll_spec(s)['seconds'] } }
      est = { audio: ElevenLabs.estimate(chars: chars, music_ms: music_ms, model: voice['model']),
              images: PrototypeImagegen.estimate(images) }
      say(ElevenLabs.format_estimate(est[:audio]))
      say("OpenAI estimate: #{est[:images][:line]}")
      unless clips.empty?
        est[:broll] = BRoll.estimate(clips)
        say("Google estimate: #{est[:broll][:line]} (ceiling $#{format('%.2f', @budget.ceiling)})")
      end
      est
    end

    # -- generation -------------------------------------------------------

    def generate_audio
      scenes.each do |scene|
        next unless narrated?(scene)

        key = WalkthroughStoryboard.audio_key(@board, scene)
        align = WalkthroughCache.path(@cache, :audio, key, 'alignment.json')
        if audio_cached?(scene) || !targeted?(scene)
          scene['narration']['measured_ms'] = ElevenLabs.measured_from(align) if File.file?(align)
          next
        end
        say("#{scene['id']}: narrating")
        res = @p[:tts].call(text: scene['narration']['text'], voice_id: voice['voice_id'], model: voice['model'],
                            output_format: voice['output_format'], settings: voice['settings'] || {},
                            pronunciations: voice['pronunciations'], cache_root: @cache)
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

    # Generates each targeted ai-broll clip (falling back to Ken Burns or the
    # static still on any failure) and writes its frame sequence under the
    # scene's frames key, like a captured scene.
    def generate_broll
      scenes.select { |s| targeted?(s) && broll?(s) }.each do |scene|
        spec = WalkthroughStoryboard.broll_spec(scene)
        res = if broll_cached?(scene)
                { mode: 'generated', path: BRoll.cached_path(@cache, BRoll.asset_key(**broll_args(scene))) }
        else
                @p[:broll].call(**broll_args(scene), fallback: spec['fallback'], cache_root: @cache, budget: @budget)
        end
        say(res[:mode] == 'generated' ? "#{scene['id']}: b-roll generated" : "#{scene['id']}: b-roll #{res[:mode]} fallback (#{res[:reason]})")
        broll_frames(scene, res)
      end
    end

    def broll_frames(scene, res)
      key = WalkthroughStoryboard.broll_keys(@board, scene, @root)['frames_key']
      out_dir = File.join(@cache, 'frames', key)
      return if File.file?(File.join(out_dir, 'cursor.json'))

      frames = scene_frames(scene)
      BRoll.make_frames(mode: res[:mode], input: res[:path] || broll_args(scene)[:source_image], out_dir: out_dir, work: @root,
                        width: viewport['w'], height: viewport['h'], fps: fps, frames: frames, docker: @p[:docker])
      overlay_frames(out_dir, File.join(@root, scene.dig('broll', 'overlay'))) if scene.dig('broll', 'overlay')
    rescue StandardError
      # cursor.json is the completion marker: a failed overlay must not leave
      # it behind, or the next render reuses the frames without their title.
      FileUtils.rm_f(File.join(out_dir, 'cursor.json'))
      raise
    end

    # A b-roll `overlay` (a transparent PNG at the viewport size, such as a
    # title) is composited onto every frame, so the clip itself stays cached.
    # The frames are root-owned, so the composite runs in the ffmpeg image.
    def overlay_frames(out_dir, overlay)
      dir = BRoll.container(out_dir, @root)
      d = Shellwords.escape(dir)
      img = Shellwords.escape(BRoll.container(overlay, @root))
      script = "mkdir -p #{d}/ov && ffmpeg -loglevel error -i #{d}/%06d.png -i #{img} " \
               "-filter_complex overlay -start_number 1 -y #{d}/ov/%06d.png && mv #{d}/ov/*.png #{d}/ && rmdir #{d}/ov"
      output, status = @p[:docker].call(ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, entrypoint: 'sh',
                                                                  args: [ '-c', script ], mounts: { @root => BRoll::WORK }))
      raise FfmpegError, "b-roll overlay failed:\n#{output.to_s.lines.last(5).join}" unless status.success?
    end

    # Captures in storyboard order, so a from_scene dependency (always a
    # lower order) is captured before the scenes that start from it. The
    # browser container opens only when at least one scene needs frames.
    # Prototype scenes and live scenes run in separate browser containers:
    # the prototype one stays offline, the live one gets the board's
    # browser options (network, extra hosts).
    def capture_frames
      with_session { |session| capture_all(session) } if capture_needed?(live: false)
      with_live_session { |session| capture_live(session) } if capture_needed?(live: true)
    end

    def capture_needed?(live: false)
      memo = {}
      scenes.any? do |scene|
        next false unless capture_target?(scene) && !broll?(scene) && live?(scene) == live

        recapture?(scene) || !captured?(scene, prep(scene, memo))
      rescue ArgumentError
        true
      end
    end

    # Captured in real time in the live browser: a live or compose scene.
    def live?(scene) = WalkthroughLive.realtime?(scene)

    def prep(scene, memo) = WalkthroughStoryboard.prepare_frames(@board, scene, @root, memo, final: @final)

    # A live scene's key cannot see the app change, so it recaptures only on
    # --recapture, or when --scene names it or a scene it takes its session from.
    def recapture?(scene) = live?(scene) && (@recapture || (!@only.nil? && capture_target?(scene)))

    # A targeted scene, or any scene whose from_scene chain reaches one: a
    # regenerated scene can change its end state, which re-keys every
    # downstream dependent, so those must be captured too or assembly misses.
    def capture_target?(scene, seen = {})
      return true if targeted?(scene)

      parent_id = scene.dig('store', 'from_scene') || WalkthroughLive.parent_id(scene)
      return false if parent_id.nil? || seen[parent_id]

      seen[parent_id] = true
      parent = scenes.find { |s| s['id'] == parent_id }
      !parent.nil? && capture_target?(parent, seen)
    end

    # A prototype capture also has to match the board's frame size; a
    # wrong-size one is recaptured rather than reused.
    def captured?(scene, prep)
      return File.file?(File.join(prep[:out_dir], 'end-state.json')) if live?(scene)

      PrototypeCapture.cached?(@board, scene, prep[:out_dir])
    end

    def with_session(&blk) = @p[:browser].call(&blk)

    def with_live_session(&blk) = @p[:live_browser].call(WalkthroughLive.browser_opts(@board), &blk)

    # Captures live scenes in order, so a session_from_scene parent recorded
    # this run hands its end session straight to the scenes after it.
    def capture_live(session)
      memo = {}
      sessions = {}
      scenes.each do |scene|
        next unless live?(scene) && capture_target?(scene)

        pr = prep(scene, memo)
        next if captured?(scene, pr) && !recapture?(scene)

        say("#{scene['id']}: capturing #{scene_frames(scene)} live frames")
        start = start_session(session, scene, sessions)
        sessions[scene['id']] = @p[:live_capture].call(**live_args(session, scene, pr[:out_dir], start), compose: compose_spec(scene, memo))
      end
    end

    # A compose scene's fields: explicit, or the link its source scene caught.
    def compose_spec(scene, memo)
      return nil unless WalkthroughLive.compose?(scene)

      from = scene.dig('compose', 'from_scene')
      path = from && File.join(prep(scenes.find { |s| s['id'] == from }, memo)[:out_dir], 'links.json')
      WalkthroughCompose.resolve(scene, links: path && File.file?(path) ? JSON.parse(File.read(path)) : nil)
    rescue ArgumentError => e
      raise WalkthroughLive::CaptureError, e.message
    end

    def live_args(session, scene, out_dir, start)
      { session: session, board: @board, scene: scene, out_dir: out_dir, secrets: secrets, browser_session: start,
        docker: @p[:docker], work: @root }
    end

    # The session a live scene starts from: a persona's login (once per
    # persona per run), an earlier scene's end session (replayed without
    # frames when that scene is cached), or none, a fresh logged-out session.
    def start_session(session, scene, sessions)
      if (name = scene['persona'])
        @personas[name] ||= begin
          say("persona #{name}: logging in")
          @p[:live_login].call(session: session, board: @board, persona: @board['personas'].fetch(name), secrets: secrets)
        end
      elsif (from = scene['session_from_scene'])
        sessions[from] ||= begin
          parent = scenes.find { |s| s['id'] == from }
          say("#{from}: replaying for its session")
          @p[:live_capture].call(**live_args(session, parent, nil, start_session(session, parent, sessions)), shots: false)
        end
      end
    end

    # --final swaps each draft image for its high-quality twin by content key;
    # a screen that references a stable path never matches, so say so and go on.
    def warn_unmatched_remap(scene, prep)
      PrototypeCapture.unmatched_remap(prep[:html_path], prep[:remap]).each do |draft|
        say("warning: #{scene['id']}: final image not inlined, #{scene.dig('screen', 'html')} does not reference images/#{draft}.png; " \
            'the screen keeps whatever its own asset path holds')
      end
    end

    def capture_all(session)
      memo = {}
      scenes.each do |scene|
        next if broll?(scene) || live?(scene)

        prep = prep(scene, memo)
        next if captured?(scene, prep) || !capture_target?(scene)

        warn_unmatched_remap(scene, prep)
        duration = PrototypeCapture.scene_duration(scene)
        say("#{scene['id']}: capturing #{scene_frames(scene)} frames")
        @p[:capture].call(session: session, html: PrototypeCapture.inline_screen(prep[:html_path], remap: prep[:remap], root: prep[:root]),
                          interactions: scene['interactions'] || [], duration_ms: duration, out_dir: prep[:out_dir],
                          state: prep[:state], prng_seed: prep[:prng_seed], viewport: PrototypeCapture.scene_viewport(@board, scene), fps: fps,
                          label: scene['id'])
        frame!(scene, prep)
      end
    end

    # A browser-framed environment scene is composited in place once
    # captured, in the pinned FFmpeg container.
    def frame!(scene, prep)
      return unless WalkthroughBrowserFrame.browser?(scene)

      WalkthroughBrowserFrame.frame_dir!(@board, scene, prep[:out_dir], work: @root, docker: @p[:docker])
    end

    def fps = WalkthroughStoryboard.fps(@board)

    def viewport = @board['viewport'] || PrototypeCapture::DEFAULT_VIEWPORT

    def scene_frames(scene) = PrototypeCapture.frame_count(PrototypeCapture.scene_duration(scene), fps)

    def generate_music(total_ms)
      return unless @board['music']
      return if File.file?(music_path(total_ms))

      say('music: composing')
      @p[:music].call(**music_block, length_ms: ElevenLabs.clamp_music_ms(total_ms), cache_root: @cache)
    end

    # -- assembly (cache only) -----------------------------------------------

    def relative(path) = path.delete_prefix("#{@root}/")

    def container(path) = File.join(WORK, relative(path))

    def host_path(container_path) = File.join(@root, container_path.delete_prefix("#{WORK}/"))

    def require_file!(path, what)
      raise MissingCacheError, "#{what} missing from cache: #{relative(path)}" unless File.file?(path)

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
        taps_file = File.join(dir, 'taps.json')
        taps = File.file?(taps_file) ? JSON.parse(File.read(taps_file)) : nil
        audio = align = nil
        if narrated?(scene)
          audio = require_file!(WalkthroughCache.path(@cache, :audio, entry['audio_key'], 'mp3'), "#{entry['id']} narration")
          align = JSON.parse(File.read(require_file!(WalkthroughCache.path(@cache, :audio, entry['audio_key'], 'alignment.json'),
                                                     "#{entry['id']} alignment")))
        end
        scene_ms = (entry['start_frame'] * 1000.0 / fps).round
        { entry: entry, scene: scene, dir: dir, cursor: cursor, taps: taps, audio: audio, alignment: align,
          scene_ms: scene_ms, offset_ms: scene_ms + PrototypeCapture.narration_start_ms(scene) }
      end
    end

    def aligned(inputs) = inputs.select { |i| i[:alignment] }

    def captions(inputs)
      # Cues never straddle a scene change: each scene packs its own words.
      cue_list = aligned(inputs).flat_map do |i|
        WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(i[:alignment], offset_ms: i[:offset_ms]))
      end
      WalkthroughCaptions.srt(WalkthroughCaptions.no_overlap(cue_list))
    end

    def duck_spans(inputs)
      WalkthroughCaptions.duck_spans(aligned(inputs).map do |i|
        timing = i[:scene]['timing'] || {}
        { offset_ms: i[:offset_ms], alignment: i[:alignment], duck_db: timing['music_duck_db'],
          attack_ms: timing['music_duck_attack_ms'], release_ms: timing['music_duck_release_ms'] }
      end)
    end

    # A burned-in render differs from a soft one but shares its manifest hash,
    # so burn gets its own directory and the two never reuse each other's mp4.
    # Camera pushes happen at assembly, so they key the directory as well.
    # The directory is keyed on what is actually captured, not only on the
    # declared keys: a live recapture keeps its key but changes its frames.
    def render_dir(manifest)
      hash = WalkthroughCache.key([ manifest['manifest_hash'], live_digest, *camera_material ])
      File.join(@cache, 'render', @burn_captions ? "#{hash}-burn" : hash)
    end

    # A digest of every live scene's captured files. A live key cannot see the
    # app change, so the bytes on disk are the only honest record of the capture.
    def live_digest
      memo = {}
      scenes.select { |s| live?(s) }.to_h do |scene|
        dir = prep(scene, memo)[:out_dir]
        files = Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }.sort
        [ scene['id'], files.map { |f| [ f.delete_prefix(dir), Digest::SHA256.file(f).hexdigest ] } ]
      end
    end

    # What a roast round reviews: the draft-quality keys (so a --final render of
    # the same authored inputs matches the roasted draft) plus the live capture.
    # Camera framing is applied at assembly, outside every capture key, so it
    # is part of what the roast reviewed: a framing edit reopens the loop.
    def content_key(draft_keys) = WalkthroughCache.key([ draft_keys, live_digest, *camera_material ])

    # Empty when no scene has a camera, so keys for camera-less boards are
    # unchanged. A zoom with no focus was once dropped at assembly; its tag
    # moves those keys so a render cached before centred framing is redone,
    # while focused cameras keep their keys.
    def camera_material
      cams = scenes.filter_map do |s|
        cam = s['camera'] or next
        cam.key?('focus') ? [ s['id'], cam ] : [ s['id'], cam, 'centred-zoom' ]
      end
      cams.empty? ? [] : [ cams ]
    end

    def plan(manifest, inputs)
      dir = render_dir(manifest)
      total = manifest.dig('timeline', 'total_ms')
      music = nil
      if @board['music']
        music = { path: container(require_file!(music_path(total), 'music')), gain_db: @board.dig('music', 'gain_db') || -18 }
      end
      { fps: fps, width: viewport['w'], height: viewport['h'], total_ms: total,
        cursor_png: container(File.join(dir, 'cursor.png')), srt: container(File.join(dir, 'captions.srt')),
        output: container(File.join(dir, 'walkthrough.mp4')), burn_captions: @burn_captions, music: music, duck_spans: duck_spans(inputs),
        voice_eq: WalkthroughStoryboard.voice_eq(@board), scenes: inputs.map { |i| plan_scene(i) },
        sfx: sfx_tracks(inputs) }
    end

    # Each scene's sound effect, placed on the timeline and cut at its scene's
    # end. A ducking effect dips under every narration span (the same ramped
    # WalkthroughDuck spans as the music), each starting duck_lead earlier.
    def sfx_tracks(inputs)
      spans = duck_spans(inputs)
      inputs.filter_map do |i|
        next unless WalkthroughStoryboard.sfx?(i[:scene])

        spec = WalkthroughStoryboard.sfx_spec(i[:scene])
        path = require_file!(File.join(@root, spec['file']), "#{i[:entry]['id']} sfx")
        start = i[:scene_ms] + (spec['start'] * 1000).round
        lead = (spec['duck_lead'] * 1000).round
        { path: container(path), start_ms: start, gain_db: spec['gain_db'],
          max_ms: [ i[:scene_ms] + i[:entry]['duration_ms'] - start, 0 ].max,
          duck_spans: spec['duck_db'] ? spans.map { |d| d.merge(start_ms: [ d[:start_ms] - lead, 0 ].max, db: spec['duck_db']) } : [] }
      end
    end

    # Interaction ops that place the pointer; key and wait never do.
    POINTER_OPS = %w[move click dblclick hover type scroll].freeze

    # The capture records a position on every frame, steps or not, so a
    # scene with nothing for the pointer to do would composite a cursor
    # parked at its resting point. A diagram scene never draws one, and a
    # prototype screen scene draws one only when an interaction places it.
    # Live, compose, and message scenes keep their recorded track.
    def drawn_cursor(input)
      scene = input[:scene]
      return [] if WalkthroughDiagram.diagram?(scene)
      return input[:cursor] if live?(scene) || broll?(scene) || scene['kind'] == 'message'
      return [] if Array(scene['interactions']).none? { |op| POINTER_OPS.include?(op['op']) }

      input[:cursor]
    end

    def plan_scene(input)
      entry = input[:entry]
      { id: entry['id'], frames_dir: container(input[:dir]), frames: entry['frames'], start_frame: entry['start_frame'],
        transition: input[:scene].dig('timing', 'transition') || WalkthroughStoryboard::DEFAULT_TRANSITION,
        cursor: drawn_cursor(input), taps: input[:taps], hero_still: input[:scene]['hero_still'] == true,
        camera: input[:scene]['camera'], stage: WalkthroughSharpness.stage_size(@board, input[:scene]),
        audio: input[:audio] && container(input[:audio]), offset_ms: input[:offset_ms] }
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
      # A failed pass 2 leaves a zero-byte mp4 behind; only a non-empty file
      # is a cached render.
      return mp4 if File.size?(mp4)

      inputs = assembly_inputs(manifest)
      plan = plan(manifest, inputs)
      FileUtils.mkdir_p(dir)
      FileUtils.cp(CURSOR_PNG, File.join(dir, 'cursor.png'))
      srt = captions(inputs)
      File.write(File.join(dir, 'captions.srt'), srt)
      File.write(File.join(dir, 'walkthrough.vtt'), WalkthroughCaptions.vtt(srt))
      WalkthroughFfmpeg.sendcmd_files(plan).each { |path, body| File.write(host_path(path), body) }
      preflight!
      probe_audio!(plan)
      measured = WalkthroughFfmpeg.parse_loudnorm(ffmpeg!(WalkthroughFfmpeg.pass1(plan), 'pass 1'))
      argv = WalkthroughFfmpeg.pass2(plan, measured)
      write_debug(dir, argv, measured) if ENV[DEBUG_ENV].to_s.strip != ''
      verify_mp4!(mp4) { pass2!(argv, plan[:total_ms]) }
    end

    def write_debug(dir, argv, measured)
      File.write(File.join(dir, 'pass2-argv.json'), JSON.pretty_generate(argv))
      File.write(File.join(dir, 'pass2-filter_complex.txt'), argv[argv.index('-filter_complex') + 1].split(';').join(";\n"))
      File.write(File.join(dir, 'loudnorm-measured.json'), JSON.pretty_generate(measured))
    end

    def pass2!(args, total_ms)
      # Named so the watchdog can `docker kill` it; stable per render so the
      # argv stays deterministic for one manifest.
      name = "cf-walkthrough-pass2-#{Process.pid}-#{Digest::SHA256.hexdigest(args.last)[0, 12]}"
      argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args, name: name,
                                      mounts: { @root => WORK }, workdir: WORK)
      kill = -> { system('docker', 'kill', name, out: File::NULL, err: File::NULL) }
      out, status = @p[:ffmpeg_watch].call(argv, limit_s: WalkthroughFfmpeg.runaway_limit(total_ms), kill: kill, label: 'ffmpeg pass 2')
      raise FfmpegError, "ffmpeg pass 2 failed:\n#{out.to_s.lines.last(20).join}" unless status.success?
    rescue FfmpegWatchdog::RunawayError => e
      raise FfmpegError, e.message
    end

    # Warns (never fails) on an audio input whose reported duration is
    # missing or wildly off its scene: a corrupt header or broken timestamps.
    def probe_audio!(plan)
      paths = WalkthroughFfmpeg.audio_expectations(plan).keys
      return if paths.empty?

      out, = @p[:docker].call(ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, entrypoint: 'sh',
                                                       args: [ '-c', WalkthroughFfmpeg.probe_script(paths) ],
                                                       mounts: { @root => WORK }, workdir: WORK))
      WalkthroughFfmpeg.probe_warnings(plan, out).each { |w| @out.puts "warning: #{w}" }
    rescue StandardError => e
      @out.puts "warning: audio probe skipped (#{e.message.lines.first&.strip})"
    end

    # A render is a cache hit by the mere presence of its mp4, so the file must
    # exist only once assembly succeeded and left real output. Any failure,
    # including a zero-byte or missing result, removes the partial file.
    def verify_mp4!(mp4)
      yield
      raise MissingCacheError, "rendered mp4 is empty: #{relative(mp4)}" unless File.size?(mp4)

      mp4
    rescue StandardError
      FileUtils.rm_f(mp4)
      raise
    end

    # -- gates --------------------------------------------------------------

    # The free UX lint: every captured scene's ux-lint.json (a lint-only
    # browser pass fills any scene captured before this lint version), plus
    # the cross-scene device-frame check, merged into ux-lint.json beside the
    # render.
    def ux_lint(manifest)
      memo = {}
      todo = []
      reports = scenes.reject { |s| broll?(s) }.map do |scene|
        prep = prep(scene, memo)
        PrototypeUxLint.read(prep[:out_dir]) || live_lint_missing!(scene) || (todo << [ scene, prep ] && nil)
      end.compact
      with_session { |session| todo.each { |scene, prep| reports << lint_scene(session, scene, prep) } } unless todo.empty?
      reports.sort_by! { |r| scenes.index { |s| s['id'] == r['scene'] } }
      reports = PrototypeUxLint.with_device_findings(reports, zoom: camera_zooms)
      dir = render_dir(manifest)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, PrototypeUxLint::REPORT), "#{JSON.pretty_generate({ 'scenes' => reports })}\n")
      say("ux lint: #{PrototypeUxLint.total(reports)} finding(s), #{relative(File.join(dir, PrototypeUxLint::REPORT))}")
      PrototypeUxLint.summary_lines(reports).each { |line| say("  #{line}") }
      reports
    end

    # A live scene's lint runs during its capture; replaying it only to lint
    # would repeat its actions against the real app.
    def live_lint_missing!(scene)
      return nil unless live?(scene)

      raise MissingCacheError, "#{scene['id']}: no current ux lint for a live scene; rerun with --recapture --scene #{scene['id']}"
    end

    # Scenes that declare a camera zoom, which alone may resize the device frame.
    def camera_zooms = scenes.filter_map { |s| (z = s.dig('camera', 'zoom')) && [ s['id'], z.to_f ] }.to_h

    def lint_scene(session, scene, prep)
      say("#{scene['id']}: ux lint")
      @p[:lint].call(session: session, html: PrototypeCapture.inline_screen(prep[:html_path], remap: prep[:remap], root: prep[:root]),
                     interactions: scene['interactions'] || [], duration_ms: PrototypeCapture.scene_duration(scene),
                     out_dir: prep[:out_dir], state: prep[:state], prng_seed: prep[:prng_seed], viewport: PrototypeCapture.scene_viewport(@board, scene),
                     fps: fps, label: scene['id'])
    end

    def roast_dir = File.join(@root, WalkthroughRoast::DIR)

    # --final refuses on any UX lint finding, or a roast loop that is missing,
    # unfinished, or holds an open P0/P1, each with its own override.
    def gate_final!(reports)
      return unless @final

      PrototypeUxLint.gate!(reports, allow: @gates[:allow_ux])
      # --no-roast is the explicit offline opt-out; otherwise a finished roast loop is required.
      WalkthroughRoast.gate!(roast_dir, allow: @gates[:allow_roast], cap_usd: roast_cap, require_roast: @gates[:roast],
                                                  content: @content_key, **roast_stop)
      say("roast gate: #{roast_verdict[:reason]}") if @gates[:roast]
    end

    # The capture-size guard, before anything is captured: every scene's
    # captured px against the slot it is drawn into on its stage, printed on
    # every render. It warns rather than refuses: the derived dpr never
    # stretches past WalkthroughSharpness::MAX_UPSCALE (the unit tests hold
    # that across every layout and zoom), so a stretch only comes from an
    # authored viewport.dpr pin, and boards pinned to dpr 1
    # before the dpr was derived must still render.
    def sharpness!
      rows = WalkthroughSharpness.upscaled(@board)
      return say('sharpness: every scene is captured at or above its slot size') if rows.empty?

      say("warning: sharpness: #{rows.size} capture(s) upscaled into their slot, text will read soft; " \
          'drop the pinned viewport.dpr')
      rows.each { |r| say("  #{WalkthroughSharpness.describe(r)}") }
    end

    def roast_cap = @gates[:roast_max_usd]

    def roast_stop = { target: @gates[:roast_target], rounds: @gates[:roast_rounds] }.compact

    def roast_verdict = WalkthroughRoast.decide(roast_dir, cap_usd: roast_cap, content: @content_key, **roast_stop)

    # One cf:roast round over the draft's keyframes and narration transcript, with
    # the estimate printed before any call, under the run spend cap. A finished
    # loop, a missing key, or an estimate past what is left skips the round (the
    # last reports its open findings); the draft itself stands.
    def draft_roast(manifest, mp4, reports)
      return say('roast: skipped (--no-roast)') unless @gates[:roast]

      verdict = roast_verdict
      return say("roast: loop finished (#{verdict[:reason]}); no further round") if verdict[:stop]

      inputs = roast_inputs(manifest, mp4, reports)
      usd = Roast.round_usd(@cache, **inputs)
      return roast_capped unless say_roast_estimate(inputs, usd)

      critic = @p[:roast].call(**inputs, cache_root: @cache, allow_sensitive: @gates[:allow_sensitive])
      Roast.write_round(roast_dir, inputs[:round], critic)
      WalkthroughRoast.record_spend(roast_dir, inputs[:round], usd)
      WalkthroughRoast.record_content(roast_dir, inputs[:round], @content_key)
      report_roast_round(inputs[:round], critic)
    rescue WalkthroughEnv::NeedsEnrollment
      raise
    rescue WalkthroughEnv::MissingKeyError, Roast::RequestError, Roast::SensitiveError, SystemCallError => e
      say("roast: skipped (#{e.message})")
    end

    def roast_inputs(manifest, mp4, reports)
      { brief: WalkthroughRoast.brief(@board), shots: extract_keyframes(manifest, mp4, reports),
        history: Roast.load_history(roast_dir), round: Roast.next_round(roast_dir),
        transcript: roast_transcript(manifest, mp4), review: WalkthroughRoast.review(@board, @gates[:roast_review] || {}) }.merge({ model: @gates[:roast_model] }.compact)
    end

    # Narration plus the rendered caption cues, so the critic judges what is said
    # next to what is shown.
    def roast_transcript(manifest, mp4)
      srt = File.join(File.dirname(mp4), 'captions.srt')
      WalkthroughRoast.transcript(@board, manifest, File.file?(srt) ? File.read(srt) : nil)
    end

    # Prints the estimate and returns whether it fits what the run cap has left.
    def say_roast_estimate(inputs, usd)
      left = [ roast_cap - WalkthroughRoast.spent(roast_dir), 0 ].max
      say("roast estimate: #{inputs[:shots].size} keyframe(s) plus transcript, $#{format('%.2f', usd)} " \
          "(run cap $#{format('%.2f', roast_cap)}, $#{format('%.2f', left)} left)")
      usd <= left + 1e-9
    end

    # The estimate passes what is left: the loop ends and the open findings are
    # reported; the cap is never raised silently.
    def roast_capped
      WalkthroughRoast.mark_capped(roast_dir)
      say("roast: spend cap reached, the estimate passes what is left (raise it with --roast-max-usd); #{roast_open_summary}")
    end

    def report_roast_round(round, critic)
      blockers = WalkthroughRoast.open_blockers(Roast.load_history(roast_dir)).size
      say("roast: #{relative(File.join(roast_dir, "round-#{round}.json"))} score #{critic['score']}/10, #{blockers} open P0/P1")
      verdict = roast_verdict
      say("roast loop: #{verdict[:stop] ? 'stop' : 'continue'}: #{verdict[:reason]}")
      return if verdict[:stop]

      say('roast loop: respond to the round, apply the accepted fixes, and render the next draft (only changed scenes re-render)')
    end

    def roast_open_summary
      history = Roast.load_history(roast_dir)
      return 'no earlier round on record' if history.empty?

      "#{WalkthroughRoast.open_blockers(history).size} open P0/P1 remain from the last round (see roast/round-#{history.last[:round]}.md)"
    end

    def extract_keyframes(manifest, mp4, reports)
      overlays = reports.to_h { |r| [ r['scene'], r['overlays'] || {} ] }
      keys = WalkthroughRoast.keyframes(manifest['scenes'], overlays)
      dir = File.join(roast_dir, 'keyframes', "round-#{Roast.next_round(roast_dir)}")
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      ffmpeg!(WalkthroughRoast.extract_args(container(mp4), keys, container(File.join(dir, '%03d.jpg'))), 'keyframes')
      keys.each_with_index.map do |key, i|
        src = File.join(dir, format('%03d.jpg', i + 1))
        dest = File.join(dir, WalkthroughRoast.keyframe_name(i, key))
        FileUtils.mv(src, dest) if File.file?(src)
        dest
      end.select { |path| File.file?(path) }
    end

    # -- driver -------------------------------------------------------------

    def call(estimate_only: false)
      WalkthroughEnv.load_secrets
      WalkthroughStoryboard.validate!(@board, root: @root)
      WalkthroughHousekeeping.ensure_location!(@root).each { |line| say(line) }
      WalkthroughCache.ensure_gitignore(@root)
      estimate
      sharpness!
      return nil if estimate_only

      generate_audio
      generate_images
      generate_broll
      capture_frames
      keys = WalkthroughStoryboard.recompute_keys(@board, @root, final: @final)
      # Authored deps stay at the authored (draft) quality: a final render's
      # keys live in the manifest only, so validate does not report stale.
      WalkthroughStoryboard.fix_keys(@board, @root, keys) unless @final
      @content_key = content_key(@final ? WalkthroughStoryboard.recompute_keys(@board, @root) : keys)
      manifest = WalkthroughManifest.build(@board, @root, keys: keys)
      generate_music(manifest.dig('timeline', 'total_ms'))
      File.write(@board_path, "#{JSON.pretty_generate(@board)}\n")
      WalkthroughManifest.write(manifest, @root)
      ux = ux_lint(manifest)
      gate_final!(ux)
      mp4 = assemble(manifest)
      draft_roast(manifest, mp4, ux) unless @final
      say("b-roll spend about $#{format('%.2f', @budget.spent)}") if @budget.spent.positive?
      say("manifest #{manifest['manifest_hash']}")
      say("mp4 #{Digest::SHA256.file(mp4).hexdigest} #{mp4}")
      paths = deliver(mp4)
      warning = WalkthroughHousekeeping.size_warning(@root)
      say(warning) if warning
      { manifest: manifest, mp4: mp4, deliverable: paths }
    end

    # -- housekeeping ---------------------------------------------------------

    def slug = @board['slug'].to_s.empty? ? File.basename(@root) : @board['slug']

    # Copies the render out of the cache to <slug>-draft.mp4 or
    # <slug>-final.mp4 (and the VTT). Only once a final is verified on disk
    # does the cache get pruned.
    def deliver(mp4)
      WalkthroughHousekeeping.mark_current_render(File.dirname(mp4))
      paths = WalkthroughHousekeeping.deliver(@root, slug, mp4, final: @final)
      say("deliverable #{paths[:mp4]}")
      prune if @final
      paths
    end

    # Drops superseded renders, dead frames and stills, and aged roast
    # responses; paid audio, music, images, and b-roll always stay.
    def prune(dry_run: false)
      plan = WalkthroughHousekeeping.plan(@root, keep: prune_keep)
      WalkthroughHousekeeping.apply!(plan, @root) unless dry_run
      WalkthroughHousekeeping.describe(plan, dry_run: dry_run).each { |line| say(line) }
      plan
    end

    def cache_report
      sizes = WalkthroughHousekeeping.report(@root)
      sizes.each { |cat, n| say(format('%-14s %s', cat, WalkthroughHousekeeping.human(n))) }
      say(format('%-14s %s', 'total', WalkthroughHousekeeping.human(sizes.values.sum)))
      sizes
    end

    # What a prune must keep. A nil category keeps all of it: the render dir
    # cannot be named without manifest.json, and frames are kept whole while
    # any scene's key cannot be computed (a from_scene parent not captured).
    def prune_keep
      { render: current_render_dirs, frames: live_frame_keys, stills: scenes.map { |s| s['id'] } }
    end

    # The dir the last render recorded, plus the soft and burned names
    # computed from manifest.json and the board. With neither, keep all.
    def current_render_dirs
      recorded = WalkthroughHousekeeping.current_render(@root)
      path = File.join(@root, 'manifest.json')
      computed = File.file?(path) ? File.basename(render_dir(JSON.parse(File.read(path)))).delete_suffix('-burn') : nil
      names = [ recorded, computed, computed && "#{computed}-burn" ].compact
      return names.uniq + [ WalkthroughHousekeeping::CURRENT_RENDER ] unless names.empty?

      say('prune: no recorded render and no manifest.json, keeping every render')
      nil
    end

    def live_frame_keys
      keys = [ false, true ].flat_map { |final| WalkthroughStoryboard.recompute_keys(@board, @root, final: final).values }
                            .map { |k| k['frames_key'] }
      return keys.uniq unless keys.include?(nil)

      say('prune: a scene frames key cannot be computed yet, keeping every frames dir')
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = 'usage: walkthrough_render.rb walkthrough/<slug> [--scene <id>] [--draft|--final] [--estimate-only] [--max-usd <n>] [--burn-captions] ' \
          '[--allow-ux-findings] [--allow-roast-findings] [--no-roast] [--allow-sensitive] [--roast-max-usd <run cap>] [--recapture]' \
          "\n       walkthrough_render.rb walkthrough/<slug> --prune [--dry-run] | --cache-report"
  dir = ARGV.first
  abort(usage) if dir.nil? || dir.start_with?('--')
  if ARGV.include?('--prune') || ARGV.include?('--cache-report')
    begin
      run = WalkthroughRender::Run.new(dir)
      ARGV.include?('--prune') ? run.prune(dry_run: ARGV.include?('--dry-run')) : run.cache_report
    rescue WalkthroughHousekeeping::Error => e
      abort(e.message)
    end
    exit 0
  end
  scene = ARGV.include?('--scene') ? (ARGV[ARGV.index('--scene') + 1] || abort(usage)) : nil
  abort('--draft and --final are exclusive') if ARGV.include?('--draft') && ARGV.include?('--final')
  max_usd = ARGV.include?('--max-usd') ? (ARGV[ARGV.index('--max-usd') + 1] || abort(usage)).to_f : BRoll::DEFAULT_CEILING_USD
  roast_usd = ARGV.include?('--roast-max-usd') ? (ARGV[ARGV.index('--roast-max-usd') + 1] || abort(usage)).to_f : nil
  begin
    roast = WalkthroughRoast.settings(Dir.pwd, roast: ARGV.include?('--no-roast') ? false : nil, max_usd: roast_usd)
  rescue DesignConfig::Error => e
    abort("CHANGE.md design block: #{e.message}")
  end
  gates = { allow_ux: ARGV.include?('--allow-ux-findings'), allow_roast: ARGV.include?('--allow-roast-findings'), allow_sensitive: ARGV.include?('--allow-sensitive'),
            roast: roast[:roast], roast_max_usd: roast[:max_usd], roast_target: roast[:target],
            roast_rounds: roast[:rounds], roast_model: roast[:model], roast_review: roast[:review] }
  begin
    WalkthroughRender::Run.new(dir, scene: scene, final: ARGV.include?('--final'), max_usd: max_usd,
                               burn_captions: ARGV.include?('--burn-captions'), gates: gates, recapture: ARGV.include?('--recapture'))
                          .call(estimate_only: ARGV.include?('--estimate-only'))
  rescue PrototypeUxLint::FindingsError, WalkthroughRoast::OpenFindingsError => e
    abort("refused: #{e.message}")
  rescue WalkthroughEnv::NeedsEnrollment => e
    WalkthroughEnv.enroll_exit!(e)
  end
end
