# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'
require_relative 'roast' unless defined?(Roast::Cli) # already loaded when roast.rb is the program
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
  # Pinned: gpt-6.1-sol, the stills roast's default (image input, Structured
  # Outputs). CF_ROAST_VIDEO_MODEL overrides it.
  MODEL = ENV.fetch('CF_ROAST_VIDEO_MODEL', 'gpt-6.1-sol')
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
          '[--round N] [--max-usd N] [--cache DIR] [--fps N] [--width N] [--estimate-only] [--allow-sensitive]'

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
    Every issue carries a timestamp (mm:ss, the moment it starts) and names the scene or cue as
    its screen. Check the brief's must-show list against what the video actually shows.
  TEXT

  SCHEMA = begin
    schema = JSON.parse(JSON.generate(Roast::SCHEMA))
    item = schema['properties']['issues']['items']
    item['required'] = %w[priority timestamp screen problem fix]
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

  def request_key(brief:, video_sha:, transcript:, history:, round:, fps:, width:)
    WalkthroughCache.key({ mode: 'video', model: MODEL, brief: brief, video: video_sha, transcript: transcript,
                           history: history, round: round, fps: fps, width: width })
  end

  def estimate(brief:, transcript:, history:, frame_count:)
    chars = SYSTEM_PROMPT.size + brief.size + transcript.to_s.size + JSON.generate(history).size + (frame_count * 12)
    input = (chars / 4) + (frame_count * FRAME_TOKENS)
    usd = ((input * Roast::PRICE_PER_MTOK[:input]) + (MAX_OUTPUT_TOKENS * Roast::PRICE_PER_MTOK[:output])) / 1_000_000.0
    { usd: usd.round(2), tokens: input }
  end

  def user_text(brief, history, round, transcript, duration)
    past = history.map do |h|
      "Round #{h[:round]} (#{h[:kind]}) critic:\n#{JSON.pretty_generate(h[:critic])}\n" \
        "Round #{h[:round]} (#{h[:kind]}) author response:\n#{h[:response] ? JSON.pretty_generate(h[:response]) : '(none recorded)'}"
    end
    [ "Round #{round}, whole-video review. Video length about #{mmss(duration)}.", "Brief:\n#{brief}",
      (transcript ? "Narration cues (WebVTT, with times):\n#{transcript}" : 'No narration transcript given.'),
      (past.empty? ? 'No earlier rounds.' : "Earlier rounds:\n#{past.join("\n\n")}"),
      'The frames follow in order, each after its time label.' ].join("\n\n")
  end

  def build_request(brief:, frames:, transcript:, history:, round:)
    content = [ { type: 'input_text', text: user_text(brief, history, round, transcript, frames.last[:time]) } ]
    frames.each do |f|
      content << { type: 'input_text', text: "[#{mmss(f[:time])}]" }
      content << { type: 'input_image', detail: 'high',
                   image_url: "data:image/jpeg;base64,#{Base64.strict_encode64(File.binread(f[:path]))}" }
    end
    { url: Roast::RESPONSES_URL,
      body: { model: MODEL, max_output_tokens: MAX_OUTPUT_TOKENS,
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
        lines << "- #{p} [#{i['timestamp']}] (#{i['screen']}): #{i['problem']}" << "  Fix: #{i['fix']}"
      end
    end
    t = critic['thirty_second_test']
    lines << '' << "30-second test: #{t['verdict']}. #{t['reason']}" << ''
    lines.join("\n")
  end

  def write_round(dir, round, critic)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "round-#{round}.video.json"), "#{JSON.pretty_generate(critic)}\n")
    File.write(File.join(dir, "round-#{round}.video.md"), render_markdown(critic, round))
  end

  private_class_method :sample!, :user_text, :render_markdown

  module Cli
    module_function

    def run(argv, out: $stdout, http: nil, docker: DEFAULT_DOCKER)
      opts = parse(argv.dup)
      WalkthroughEnv.load_secrets
      critique(opts, out, http, docker)
      0
    rescue UsageError, OptionParser::ParseError => e
      out.puts("error: #{e.message}", USAGE)
      2
    rescue Roast::CeilingError, Roast::SensitiveError, Roast::RequestError, FfmpegError, WalkthroughEnv::MissingKeyError, SystemCallError => e
      out.puts("error: #{e.message}")
      1
    end

    def parse(args)
      opts = { max_usd: Roast::DEFAULT_CEILING_USD, cache: '.cache', out_dir: Roast::DEFAULT_OUT_DIR, fps: FPS, width: WIDTH }
      OptionParser.new do |o|
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
      end.parse!(args)
      raise UsageError, '--video is required' unless opts[:video]
      raise UsageError, '--brief is required' unless opts[:brief_file]

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
      Roast.check_sensitive!(brief: brief, transcript: transcript, history: history, allow: opts[:allow_sensitive])
      key = RoastVideo.request_key(brief: brief, video_sha: Digest::SHA256.file(opts[:video]).hexdigest, transcript: transcript,
                                   history: history, round: round, fps: opts[:fps], width: opts[:width])
      cache = [ opts[:cache], :roasts, key, 'json' ]
      cached = File.file?(WalkthroughCache.path(*cache))
      est = RoastVideo.estimate(brief: brief, transcript: transcript, history: history, frame_count: frames.size)
      usd = cached ? 0.0 : est[:usd]
      out.puts("roast estimate: #{model_line(frames, est, cached)}, $#{format('%.2f', usd)} to spend")
      raise Roast::CeilingError, "$#{format('%.2f', usd)} would pass the $#{format('%.2f', opts[:max_usd])} ceiling" if usd > opts[:max_usd] + 1e-9
      return if opts[:estimate_only]

      request = RoastVideo.build_request(brief: brief, frames: frames, transcript: transcript, history: history, round: round)
      critic = fetch_critic(cache, request, out, http)
      RoastVideo.write_round(opts[:out_dir], round, critic)
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

    def model_line(frames, est, cached)
      return '1 call (cached)' if cached

      "1 call to #{MODEL}, #{frames.size} frame(s) over #{RoastVideo.mmss(frames.last[:time])}, " \
        "about #{est[:tokens]} tokens in, up to #{MAX_OUTPUT_TOKENS} out, about $#{format('%.2f', est[:usd])}"
    end
    private_class_method :fetch_critic, :model_line
  end
end
