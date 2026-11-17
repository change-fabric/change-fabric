# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'
require_relative 'roast' unless defined?(Roast::Cli) # already loaded when roast.rb is the program
require_relative 'roast_lens'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_env'

# cf:roast --video: a whole-sequence roast of a finished MP4. The OpenAI API
# takes no video, so the MP4 is sampled with ffmpeg (about 1.5 fps, 1280px
# wide) and every frame goes to the critic in ONE request, in order, each
# after an mm:ss label, together with the narration cues from the .vtt beside
# the MP4. That lets the critic judge what stills cannot: narration against
# picture, pacing, cuts, cursor motion, story, and text as it plays. The reply
# is the stills JSON shape plus a timestamp per issue, logged as
# round-N.video.json and round-N.video.md beside the stills rounds.
module RoastVideo
  # The model comes from the stills chain (Roast.model_for, video kind, Sol by
  # default), with CF_ROAST_VIDEO_MODEL as a video-only override checked ahead
  # of CF_ROAST_MODEL. A --model flag still wins over both.
  KIND = 'video'
  FPS = 1.5
  WIDTH = 1280
  JPEG_QUALITY = 4
  # A 1280x720 frame at high detail, rounded up; a planning figure, not a quote.
  FRAME_TOKENS = 1105
  MAX_OUTPUT_TOKENS = 6000
  WORK = '/work'
  KIND_STILLS = 'stills'
  KIND_VIDEO = 'video'
  DEFAULT_DOCKER = ->(argv) { Open3.capture2e(*argv) }
  USAGE = 'usage: roast.rb --video MP4 --brief FILE [--transcript VTT] [--history DIR] [--out-dir DIR] ' \
          '[--round N] [--max-usd N] [--model NAME|terra|sol] [--effort LEVEL] [--repo DIR] [--cache DIR] [--fps N] [--width N] [--lens NAME]... [--estimate-only] [--allow-sensitive]'

  # The craft section of the video rubric, adapted in our own words from the
  # editorial, visual, audio, and technical checklists of gitethanwoo/video-editing
  # (MIT, notice in THIRD_PARTY_NOTICES). Bump CRAFT_VERSION when it changes:
  # each round records the version it was judged under.
  CRAFT_VERSION = 1
  CRAFT_RUBRIC = <<~TEXT.chomp
    Craft. Judge the film as a directed piece, not only as a correct one. Start the problem of
    every craft issue with "craft:" and its area name, for example "craft: density:".
    - composition: each frame carries one idea. The subject sits near the center or on a clear
      axis, with generous empty space around it; nothing hugs the top-left corner, nothing crowds
      the frame edge, and the eye knows where to land within a second.
    - type: real typefaces, a display face for statements and a clean UI face for labels, never a
      browser fallback. Sizes step on one scale, body text reads comfortably at 1080p, and every
      line holds strong contrast against what sits behind it.
    - density: a frame shows no more than a viewer can take in while it is on screen. Too many
      nodes, labels, or cards at once is a finding; propose what to cut or move to its own beat.
    - motion grammar: one easing family across the film, entrances and exits that mirror each
      other, nothing that pops in unannounced, and motion that lands on the word the narrator is
      saying rather than before or long after it.
    - hook and close: the first seconds earn attention with the problem or the payoff, not a logo
      or a title card; the last frame lands one clear takeaway and holds long enough to read.
    A craft P0 is a frame a viewer cannot read or follow; a craft P1 is a frame that reads but
    looks assembled rather than directed.
  TEXT

  SYSTEM_PROMPT = <<~TEXT
    #{Roast::SYSTEM_PROMPT}
    This round you are watching the whole finished video, not stills. You get every sampled frame in
    order, each labelled with its mm:ss time, plus the narration cues with their times. Judge what
    stills cannot show:
    - narration against picture: does what is said match what is on screen at that moment?
    - pacing: scenes that drag (static frames under long narration) or rush (gone before read);
    - abrupt cuts and transitions between scenes;
    - cursor motion: can a viewer follow where the cursor goes and what it clicks?
    - voice and music balance, inferred from cue density and gaps (you cannot hear the audio;
      say so if an issue rests on it);
    - whether the story is coherent for the target audience in the brief, start to end;
    - readability of on-screen text for the time it is actually visible.
    Every issue carries a timestamp (mm:ss, the moment it starts) and names the scene or cue in
    its where field. Check the brief's must-show list against what the video actually shows.

    #{CRAFT_RUBRIC}
  TEXT

  SCHEMA = begin
    schema = JSON.parse(JSON.generate(Roast::SCHEMA))
    item = schema['properties']['issues']['items']
    item['required'] = %w[priority timestamp where problem fix saving]
    item['properties'] = { 'priority' => item['properties']['priority'], 'timestamp' => { 'type' => 'string' } }
                         .merge(item['properties'].except('priority'))
    schema.freeze
  end

  class UsageError < StandardError; end
  class FfmpegError < StandardError; end

  module_function

  def mmss(seconds)
    s = seconds.floor
    format('%02d:%02d', s / 60, s % 60)
  end

  # Samples the MP4 into JPEGs, cached by the MP4 digest and sampling settings.
  # Returns [{ path:, time: }] in order.
  def frames(mp4, cache_root:, fps: FPS, width: WIDTH, docker: DEFAULT_DOCKER)
    key = WalkthroughCache.key({ video_frames: Digest::SHA256.file(mp4).hexdigest, fps: fps, width: width,
                                 q: JPEG_QUALITY, ffmpeg: ChangeDocker::FFMPEG_IMAGE })
    dir = File.join(cache_root, 'roast-video-frames', key)
    unless File.file?(File.join(dir, '.done'))
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      sample!(mp4, dir, fps, width, docker)
      File.write(File.join(dir, '.done'), '')
    end
    Dir.glob(File.join(dir, '*.jpg')).sort.each_with_index.map { |p, i| { path: p, time: i / fps.to_f } }
  end

  def sample!(mp4, dir, fps, width, docker)
    src = File.dirname(File.expand_path(mp4))
    args = [ '-hide_banner', '-nostdin', '-y', '-i', "/src/#{File.basename(mp4)}", '-an',
             '-vf', "fps=#{fps},scale=#{width}:-2:flags=lanczos", '-q:v', JPEG_QUALITY.to_s, "#{WORK}/%05d.jpg" ]
    argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args,
                                    mounts: { src => '/src', File.expand_path(dir) => WORK }, workdir: WORK)
    output, status = docker.call(argv)
    raise FfmpegError, "frame sampling failed:\n#{output.to_s.lines.last(8).join}" unless status.success?
    raise FfmpegError, 'frame sampling wrote no frames' if Dir.glob(File.join(dir, '*.jpg')).empty?
  end

  # Stills rounds and earlier video rounds, each with its response file.
  def load_history(dir)
    stills = Roast.load_history(dir).map { |h| h.merge(kind: KIND_STILLS) }
    return stills unless dir && File.directory?(dir)

    video = Dir.glob(File.join(dir, 'round-*.video.json')).filter_map do |path|
      n = File.basename(path)[/\Around-(\d+)\.video\.json\z/, 1] or next
      response = File.join(dir, "round-#{n}.video.response.json")
      { round: n.to_i, kind: KIND_VIDEO, critic: JSON.parse(File.read(path)),
        response: File.file?(response) ? JSON.parse(File.read(response)) : nil }
    end
    (stills + video).sort_by { |h| [ h[:round], h[:kind] ] }
  end

  # Defaults to the latest stills round (pairing with it) unless that round
  # already has a video roast, then the next number.
  def default_round(dir)
    hist = load_history(dir)
    stills = hist.select { |h| h[:kind] == KIND_STILLS }.map { |h| h[:round] }.max
    videos = hist.select { |h| h[:kind] == KIND_VIDEO }.map { |h| h[:round] }
    return stills if stills && !videos.include?(stills)

    ([ stills, *videos ].compact.max || 0) + 1
  end

  # flag, CF_ROAST_VIDEO_MODEL, then the stills chain (CF_ROAST_MODEL, repo config, video default).
  def model_for(flag: nil, config: nil, env: ENV)
    pick = [ flag, env['CF_ROAST_VIDEO_MODEL'] ].find { |v| !v.to_s.strip.empty? }
    pick ? Roast.resolve_model(pick) : Roast.model_for(kind: KIND, config: config, env: env)
  end

  # The craft version and any lenses join the key, so a critic cached under an
  # older rubric is never recorded as a craft round.
  def request_key(brief:, video_sha:, transcript:, history:, round:, fps:, width:, model: model_for, effort: Roast::DEFAULT_EFFORT, lenses: [])
    WalkthroughCache.key({ mode: 'video', model: model, brief: brief, video: video_sha, transcript: transcript,
                           history: history, round: round, fps: fps, width: width, craft: CRAFT_VERSION }
                           .merge(lenses.empty? ? {} : { lenses: lenses.map { |l| [ l.name, Digest::SHA256.hexdigest(l.body) ] } })
                           .merge(Roast.effort_key(effort)))
  end

  def estimate(brief:, transcript:, history:, frame_count:, model: model_for, lenses: [])
    chars = lenses.sum { |l| l.name.size + l.body.size } + SYSTEM_PROMPT.size + brief.size + transcript.to_s.size + JSON.generate(history).size + (frame_count * 12)
    input = (chars / 4) + (frame_count * FRAME_TOKENS)
    Roast.priced_usd(model, input, MAX_OUTPUT_TOKENS)
  end

  def user_text(brief, history, round, transcript, duration, lenses = [])
    past = history.map do |h|
      "Round #{h[:round]} (#{h[:kind]}) critic:\n#{JSON.pretty_generate(h[:critic])}\n" \
        "Round #{h[:round]} (#{h[:kind]}) author response:\n#{h[:response] ? JSON.pretty_generate(h[:response]) : '(none recorded)'}"
    end
    [ "Round #{round}, whole-video review. Video length about #{mmss(duration)}.", Roast.lens_text(lenses), "Brief:\n#{brief}",
      (transcript ? "Narration cues (WebVTT, with times):\n#{transcript}" : 'No narration transcript given.'),
      (past.empty? ? 'No earlier rounds.' : "Earlier rounds:\n#{past.join("\n\n")}"),
      'The frames follow in order, each after its time label.' ].compact.join("\n\n")
  end

  def build_request(brief:, frames:, transcript:, history:, round:, model: model_for, effort: Roast::DEFAULT_EFFORT, lenses: [])
    content = [ { type: 'input_text', text: user_text(brief, history, round, transcript, frames.last[:time], lenses) } ]
    frames.each do |f|
      content << { type: 'input_text', text: "[#{mmss(f[:time])}]" }
      content << { type: 'input_image', detail: 'high',
                   image_url: "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(f[:path]))}" }
    end
    { url: Roast::RESPONSES_URL,
      body: { model: model, max_output_tokens: MAX_OUTPUT_TOKENS, reasoning: { effort: effort },
              input: [ { role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: content } ],
              text: { format: { type: 'json_schema', name: 'video_roast', strict: true, schema: SCHEMA } } } }
  end

  def parse_critic(body)
    critic = Roast.parse_critic(body)
    bad = critic['issues'].find { |i| !i['timestamp'].to_s.match?(/\A\d{1,2}:\d{2}\z/) }
    raise Roast::RequestError, "video roast issue has a bad timestamp: #{bad['timestamp'].inspect}" if bad

    critic
  end

  def render_markdown(critic, round)
    lines = [ "# Video roast round #{round}", '', "Score: #{critic['score']}/10", '', critic['summary'], '' ]
    Roast::PRIORITIES.each do |p|
      critic['issues'].select { |i| i['priority'] == p }.each do |i|
        lines << "- #{Roast.id_label(i)}#{p} [#{i['timestamp']}] (#{Roast.location(i)}): #{i['problem']}" << "  Fix: #{i['fix']}"
        saving = Roast.saving_line(i)
        lines << saving if saving
      end
    end
    t = critic['thirty_second_test']
    lines << '' << "30-second test: #{t['verdict']}. #{t['reason']}" << ''
    lines.join("\n")
  end

  # The round JSON carries what it judged: the craft rubric version and the
  # SHA-256 of the exact MP4, which WalkthroughCraft binds approval to.
  def write_round(dir, round, critic, master_sha256: nil)
    critic = Roast.normalize_critic(critic, round, prefix: "R#{round}V")
    FileUtils.mkdir_p(dir)
    record = master_sha256 ? critic.merge('craft' => { 'version' => CRAFT_VERSION, 'master_sha256' => master_sha256 }) : critic
    File.write(File.join(dir, "round-#{round}.video.json"), "#{JSON.pretty_generate(record)}\n")
    File.write(File.join(dir, "round-#{round}.video.md"), render_markdown(critic, round))
  end

  private_class_method :sample!, :user_text, :render_markdown

  module Cli
    module_function

    def run(argv, out: $stdout, http: nil, docker: DEFAULT_DOCKER)
      opts = parse(argv.dup)
      critique(opts, out, http, docker)
      0
    rescue UsageError, Roast::UsageError, OptionParser::ParseError, RoastLens::UnknownLens => e
      out.puts("error: #{e.message}", USAGE)
      2
    rescue WalkthroughEnv::NeedsEnrollment => e
      WalkthroughEnv.enroll(e, out: out)
    rescue CfProviderError::Failure => e
      WalkthroughEnv.key_error(e, out: out)
    rescue Roast::CeilingError, Roast::SensitiveError, Roast::RequestError, FfmpegError, WalkthroughEnv::MissingKeyError, SystemCallError,
           DesignConfig::Error => e
      out.puts("error: #{e.message}")
      1
    end

    def parse(args)
      repo = Roast::Cli.repo_arg(args)
      opts = { max_usd: Roast::DEFAULT_CEILING_USD, cache: '.cache', out_dir: Roast::DEFAULT_OUT_DIR, fps: FPS, width: WIDTH,
               effort: Roast::DEFAULT_EFFORT, config_model: Roast::Cli.configured(repo)[:model], lens_names: [] }
      OptionParser.new do |o|
        o.on('--model NAME') { |v| opts[:model] = v }
        o.on('--effort LEVEL') { |v| opts[:effort] = v }
        o.on('--video MP4') { |v| opts[:video] = v }
        o.on('--brief FILE') { |v| opts[:brief_file] = v }
        o.on('--transcript FILE') { |v| opts[:transcript_file] = v }
        o.on('--history DIR') { |v| opts[:history] = v }
        o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
        o.on('--round N', Integer) { |v| opts[:round] = v }
        o.on('--max-usd N', Float) { |v| opts[:max_usd] = v }
        o.on('--cache DIR') { |v| opts[:cache] = v }
        o.on('--fps N', Float) { |v| opts[:fps] = v }
        o.on('--width N', Integer) { |v| opts[:width] = v }
        o.on('--estimate-only') { opts[:estimate_only] = true }
        o.on('--allow-sensitive') { opts[:allow_sensitive] = true }
        o.on('--lens NAME') { |v| opts[:lens_names] << v }
      end.parse!(args)
      opts[:lenses] = RoastLens.resolve(opts[:lens_names])
      raise UsageError, '--video is required' unless opts[:video]
      raise UsageError, '--brief is required' unless opts[:brief_file]

      opts[:model] = RoastVideo.model_for(flag: opts[:model], config: opts[:config_model])
      opts[:effort] = Roast.check_effort!(opts[:effort], opts[:model])

      opts[:transcript_file] ||= begin
        vtt = File.join(File.dirname(opts[:video]), "#{File.basename(opts[:video], '.*')}.vtt")
        vtt if File.file?(vtt)
      end
      opts
    end

    def critique(opts, out, http, docker)
      [ opts[:video], opts[:brief_file], opts[:transcript_file] ].compact.each { |f| raise Errno::ENOENT, f unless File.file?(f) }
      frames = RoastVideo.frames(opts[:video], cache_root: opts[:cache], fps: opts[:fps], width: opts[:width], docker: docker)
      brief = File.read(opts[:brief_file]).strip
      transcript = opts[:transcript_file] && File.read(opts[:transcript_file]).strip
      dir = opts[:history] || opts[:out_dir]
      history = RoastVideo.load_history(dir)
      round = opts[:round] || RoastVideo.default_round(opts[:out_dir])
      lenses = opts[:lenses]
      Roast.check_sensitive!(brief: brief, transcript: transcript, history: history, lenses: lenses, allow: opts[:allow_sensitive])
      sha = Digest::SHA256.file(opts[:video]).hexdigest
      key = RoastVideo.request_key(brief: brief, video_sha: sha, transcript: transcript,
                                   history: history, round: round, fps: opts[:fps], width: opts[:width],
                                   model: opts[:model], effort: opts[:effort], lenses: lenses)
      cache = [ opts[:cache], :roasts, key, 'json' ]
      cached = File.file?(WalkthroughCache.path(*cache))
      est = RoastVideo.estimate(brief: brief, transcript: transcript, history: history, frame_count: frames.size, model: opts[:model], lenses: lenses)
      usd = cached ? 0.0 : est[:usd]
      warning = Roast.price_warning(est)
      out.puts(warning) if warning && !cached
      out.puts("roast estimate: #{model_line(frames, est, cached, lenses)}, $#{format('%.2f', usd)} to spend")
      raise Roast::CeilingError, "$#{format('%.2f', usd)} would pass the $#{format('%.2f', opts[:max_usd])} ceiling" if usd > opts[:max_usd] + 1e-9
      return if opts[:estimate_only]

      request = RoastVideo.build_request(brief: brief, frames: frames, transcript: transcript, history: history, round: round,
                                           model: opts[:model], effort: opts[:effort], lenses: lenses)
      critic = fetch_critic(cache, request, out, http)
      RoastVideo.write_round(opts[:out_dir], round, critic, master_sha256: sha)
      out.puts("roast: #{File.join(opts[:out_dir], "round-#{round}.video.json")} score #{critic['score']}/10")
    end

    # The cached critic JSON, making the paid call (and printing its usage) only on a miss.
    def fetch_critic(cache, request, out, http)
      path = WalkthroughCache.fetch(*cache) do |tmp|
        body = Roast.post(request, http)
        if (u = body['usage'])
          out.puts("roast usage: #{u['input_tokens']} tokens in, #{u['output_tokens']} out")
        end
        File.write(tmp, JSON.generate(RoastVideo.parse_critic(body)))
      end
      JSON.parse(File.read(path))
    end

    def model_line(frames, est, cached, lenses = [])
      return '1 call (cached)' if cached

      "1 call to #{est[:model]}, #{frames.size} frame(s)#{Roast::Cli.lens_count(lenses: lenses)} over #{RoastVideo.mmss(frames.last[:time])}, " \
        "about #{est[:tokens]} tokens in, up to #{MAX_OUTPUT_TOKENS} out, about $#{format('%.2f', est[:usd])}"
    end
    private_class_method :fetch_critic, :model_line
  end
end
