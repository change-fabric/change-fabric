# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'uri'
require_relative 'change_docker'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_env'

# Short AI-generated B-roll for cf:b-roll: one still becomes one silent clip
# through the Gemini Interactions API (image to video only), cached by content
# hash. Never for UI and never the only path: every shot has a deterministic
# fallback (Ken Burns on the source still, then the static still), so a failed
# or over-budget generation never blocks a render. A cached run needs no key
# and costs nothing; callers print `estimate` before any paid call.
module BRoll
  class Error < StandardError; end
  class RetiredModelError < Error; end
  class CeilingError < Error; end
  class RequestError < Error; end
  class PollTimeoutError < Error; end
  class GenerationFailedError < Error; end
  class ProbeError < Error; end
  class FfmpegError < Error; end

  MODEL = ENV.fetch('CF_BROLL_MODEL', 'gemini-omni-1.1-flash')
  # Ids Google has shut down (Veo previews and 3.x, the Omni preview).
  RETIRED_MODEL_RE = /\A(?:veo-|gemini-omni-flash-preview\z)/
  # Approximate USD per output second at 720p (5,792 tokens/s at $17.50 per 1M).
  PRICE_PER_SECOND = 0.10
  DEFAULT_CEILING_USD = 1.0
  RESOLUTION = '720p'
  ASPECT_RATIO = '16:9'
  FALLBACKS = %w[kenburns static].freeze
  MIME = { '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.webp' => 'image/webp' }.freeze
  API = 'https://generativelanguage.googleapis.com/v1beta'
  INTERACTIONS_URL = "#{API}/interactions".freeze
  POLL_INTERVAL = 5
  POLL_TIMEOUT = 300
  MIN_PROBE_SECONDS = 0.5
  WORK = '/work'
  DEFAULT_DOCKER = ->(argv) { Open3.capture2e(*argv) }

  module_function

  def check_model!(model)
    raise RetiredModelError, "model #{model} is retired; use #{MODEL}" if model.to_s.match?(RETIRED_MODEL_RE)

    model
  end

  def asset_key(source_image:, prompt:, seconds:, model: MODEL, resolution: RESOLUTION, aspect_ratio: ASPECT_RATIO)
    WalkthroughCache.key({ source: Digest::SHA256.file(source_image).hexdigest, prompt: prompt, seconds: seconds,
                           model: model, resolution: resolution, aspect_ratio: aspect_ratio })
  end

  def cost_usd(seconds) = seconds * PRICE_PER_SECOND

  # clips: [{ seconds: }]. Returns { count:, seconds:, usd:, line: }.
  def estimate(clips)
    seconds = clips.sum { |clip| clip[:seconds].to_i }
    usd = cost_usd(seconds).round(2)
    { count: clips.size, seconds: seconds, usd: usd,
      line: "#{clips.size} b-roll clip(s), #{seconds}s at #{RESOLUTION}, about $#{format('%.2f', usd)}" }
  end

  # Running spend against an explicit ceiling; charge! raises before a paid
  # call that would pass it.
  class Budget
    attr_reader :spent, :ceiling

    def initialize(ceiling = DEFAULT_CEILING_USD)
      @ceiling = ceiling
      @spent = 0.0
    end

    def charge!(usd, label = 'clip')
      if @spent + usd > @ceiling + 1e-9
        raise CeilingError, "#{label}: $#{format('%.2f', usd)} would pass the $#{format('%.2f', @ceiling)} " \
                            "ceiling (spent $#{format('%.2f', @spent)})"
      end

      @spent += usd
    end
  end

  # The pure request description. The key is added at send time.
  def build_request(source_image:, prompt:, seconds:, model: MODEL, aspect_ratio: ASPECT_RATIO, resolution: RESOLUTION)
    mime = MIME.fetch(File.extname(source_image).downcase) { raise ArgumentError, "unsupported image type #{File.extname(source_image)}" }
    text = "#{prompt} Clip length about #{seconds} seconds. No audio, no dialogue, no on-screen text."
    { url: INTERACTIONS_URL,
      body: { model: model,
              input: [ { type: 'image', data: Base64.strict_encode64(File.binread(source_image)), mime_type: mime },
                       { type: 'text', text: text } ],
              generation_config: { video_config: { task: 'image_to_video' } },
              response_format: { type: 'video', aspect_ratio: aspect_ratio, resolution: resolution, delivery: 'uri' } } }
  end

  # The video item of a model_output step: { data: bytes } or { uri: }.
  def extract_video(body)
    item = Array(body['steps']).select { |s| s['type'] == 'model_output' }
                               .flat_map { |s| Array(s['content']) }.find { |c| c['type'] == 'video' }
    raise RequestError, 'b-roll response carried no video' unless item
    return { data: Base64.decode64(item['data']) } if item['data']
    return { uri: item['uri'] } if item['uri']

    raise RequestError, 'b-roll video item had neither data nor uri'
  end

  def generate(source_image:, prompt:, seconds:, cache_root:, model: MODEL, http: nil, budget: Budget.new, validator: nil,
               sleeper: ->(s) { sleep(s) }, poll_interval: POLL_INTERVAL, poll_timeout: POLL_TIMEOUT)
    check_model!(model)
    key = asset_key(source_image: source_image, prompt: prompt, seconds: seconds, model: model)
    validator ||= ->(path) { probe!(path) }
    WalkthroughCache.fetch(cache_root, :broll, key, 'mp4') do |tmp|
      api_key = WalkthroughEnv.gemini_key!
      pending = pending_path(cache_root, key)
      state = File.file?(pending) ? JSON.parse(File.read(pending)) : nil
      state ||= start_job(source_image, prompt, seconds, model, api_key, http, budget, tmp, pending)
      finish_job(state, api_key, http, tmp, pending, sleeper, poll_interval, poll_timeout) if state
      validator.call(tmp)
      FileUtils.rm_f(pending)
    end
  end

  def cached_path(cache_root, key) = WalkthroughCache.path(cache_root, :broll, key, 'mp4')

  def pending_path(cache_root, key) = WalkthroughCache.path(cache_root, :broll, key, 'pending.json')

  # Posts the job. Inline data is written to tmp (returns nil); a uri is
  # persisted so an interrupted run resumes without a second paid call.
  def start_job(source_image, prompt, seconds, model, api_key, http, budget, tmp, pending)
    budget.charge!(cost_usd(seconds.to_i), File.basename(source_image))
    request = build_request(source_image: source_image, prompt: prompt, seconds: seconds, model: model)
    body = JSON.parse(send_request(post(request[:url], JSON.generate(request[:body]), api_key), http).body)
    video = extract_video(body)
    if video[:data]
      File.binwrite(tmp, video[:data])
      return nil
    end

    state = { 'uri' => video[:uri], 'interaction_id' => body['id'] }
    FileUtils.mkdir_p(File.dirname(pending))
    File.write(pending, JSON.generate(state))
    state
  end

  def finish_job(state, api_key, http, tmp, pending, sleeper, interval, timeout)
    id = state['uri'][%r{files/([^/?:]+)}, 1] or raise RequestError, 'b-roll uri carried no file id'
    wait_active(id, api_key, http, pending, sleeper, interval, timeout)
    File.binwrite(tmp, send_request(get("#{API}/files/#{id}:download?alt=media", api_key), http).body)
  end

  def wait_active(id, api_key, http, pending, sleeper, interval, timeout)
    attempts = [ (timeout.to_f / interval).ceil, 1 ].max
    attempts.times do
      state = JSON.parse(send_request(get("#{API}/files/#{id}", api_key), http).body)['state']
      return if state == 'ACTIVE'

      if state == 'FAILED'
        FileUtils.rm_f(pending)
        raise GenerationFailedError, "b-roll file #{id} failed"
      end
      sleeper.call(interval)
    end
    raise PollTimeoutError, "b-roll file #{id} not ACTIVE after #{timeout}s; rerun to resume"
  end

  def post(url, json, api_key)
    req = Net::HTTP::Post.new(URI(url))
    req['Content-Type'] = 'application/json'
    req['x-goog-api-key'] = api_key
    req.body = json
    req
  end

  def get(url, api_key)
    req = Net::HTTP::Get.new(URI(url))
    req['x-goog-api-key'] = api_key
    req
  end

  def send_request(req, http)
    response = (http || default_http).request(req)
    return response if response.is_a?(Net::HTTPSuccess)

    # Google error bodies describe the request, never the key.
    raise RequestError, "b-roll request failed: HTTP #{response.code} #{response.body.to_s[0, 300]}".strip
  end

  def default_http
    uri = URI(API)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 600
    http
  end

  # -- fallback chain ------------------------------------------------------

  # { mode: 'generated', path: } or { mode: fallback, path: nil, reason: }.
  # Any named failure, a missing key, or the ceiling degrades to the fallback;
  # it never raises, so a render is never blocked by generation.
  def generate_or_fallback(fallback: 'kenburns', **args)
    { mode: 'generated', path: generate(**args) }
  rescue Error, WalkthroughEnv::MissingKeyError => e
    { mode: fallback, path: nil, reason: e.message }
  end

  # The mode a render would use right now: generated when the clip is cached.
  def mode_for(cache_root, fallback, source_image:, prompt:, seconds:, model: MODEL)
    key = asset_key(source_image: source_image, prompt: prompt, seconds: seconds, model: model)
    File.file?(cached_path(cache_root, key)) ? 'generated' : fallback
  end

  def frames_key(mode:, source_sha:, viewport:, fps:, frames:, clip_key: nil, ffmpeg_image: ChangeDocker::FFMPEG_IMAGE)
    WalkthroughCache.key({ broll_frames: mode, source: source_sha, clip: clip_key, viewport: viewport, fps: fps,
                           frames: frames, ffmpeg: ffmpeg_image })
  end

  # -- ffmpeg --------------------------------------------------------------

  def fit_filter(width, height)
    "scale=#{width}:#{height}:force_original_aspect_ratio=decrease,pad=#{width}:#{height}:(ow-iw)/2:(oh-ih)/2,setsar=1"
  end

  # Argv (container paths) that writes `frames` PNGs to out_dir: the clip
  # scaled and padded to the viewport at the walkthrough fps with no audio and
  # its last frame held; or the still panned (kenburns) or held (static).
  def frame_args(mode:, input:, out_dir:, width:, height:, fps:, frames:)
    head = [ '-hide_banner', '-nostdin', '-y' ]
    fit = fit_filter(width, height)
    out = [ '-frames:v', frames.to_s, File.join(out_dir, '%06d.png') ]
    case mode
    when 'generated'
      hold = (frames.to_f / fps).ceil + 1
      head + [ '-i', input, '-an', '-vf', "#{fit},fps=#{fps},tpad=stop_mode=clone:stop_duration=#{hold}" ] + out
    when 'kenburns'
      zoom = "scale=#{width * 4}:#{height * 4}:flags=lanczos,zoompan=z='min(zoom+0.0008,1.12)':d=#{frames}:" \
             "x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=#{width}x#{height}:fps=#{fps}"
      head + [ '-i', input, '-vf', "#{fit},#{zoom}" ] + out
    when 'static'
      head + [ '-loop', '1', '-i', input, '-vf', "#{fit},fps=#{fps}" ] + out
    else
      raise ArgumentError, "unknown b-roll mode #{mode.inspect}"
    end
  end

  # Writes the frame sequence plus an empty cursor.json (the completion
  # marker the renderer reads like a captured scene). `work` is the host
  # directory mounted at /work; input and out_dir are inside it.
  def make_frames(mode:, input:, out_dir:, work:, width:, height:, fps:, frames:, docker: DEFAULT_DOCKER)
    FileUtils.rm_rf(out_dir)
    FileUtils.mkdir_p(out_dir)
    args = frame_args(mode: mode, input: container(input, work), out_dir: container(out_dir, work), width: width,
                      height: height, fps: fps, frames: frames)
    output, status = docker.call(ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args,
                                                          mounts: { work => WORK }, workdir: WORK))
    raise FfmpegError, "b-roll #{mode} frames failed:\n#{output.to_s.lines.last(10).join}" unless status.success?
    raise FfmpegError, "b-roll #{mode} wrote no frames" unless File.file?(File.join(out_dir, '000001.png'))

    File.write(File.join(out_dir, 'cursor.json'), '[]')
    out_dir
  end

  def container(path, work) = File.join(WORK, path.delete_prefix("#{work}/"))

  # -- probe ---------------------------------------------------------------

  def probe!(path, docker: DEFAULT_DOCKER)
    dir = File.dirname(File.expand_path(path))
    args = %w[-v error -print_format json -show_streams -show_format] + [ File.join(WORK, File.basename(path)) ]
    argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, entrypoint: 'ffprobe',
                                    mounts: { dir => WORK }, workdir: WORK, args: args)
    output, status = docker.call(argv)
    raise ProbeError, "ffprobe failed:\n#{output.to_s.lines.last(5).join}" unless status.success?

    check_probe!(JSON.parse(output))
  rescue JSON::ParserError
    raise ProbeError, 'ffprobe output was not JSON'
  end

  def check_probe!(info)
    video = Array(info['streams']).find { |s| s['codec_type'] == 'video' }
    raise ProbeError, 'clip has no video stream' unless video
    raise ProbeError, 'clip has no dimensions' unless video['width'].to_i.positive? && video['height'].to_i.positive?
    raise ProbeError, "clip is shorter than #{MIN_PROBE_SECONDS}s" if info.dig('format', 'duration').to_f < MIN_PROBE_SECONDS

    nil
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = 'usage: b_roll.rb <image> <prompt> <cache-root> [--seconds N] [--max-usd X] [--model ID] [--estimate-only]'
  image, prompt, cache = ARGV
  abort(usage) unless image && prompt && cache && !image.start_with?('--')
  flag = ->(name, default) { ARGV.include?(name) ? ARGV[ARGV.index(name) + 1] : default }
  seconds = flag.call('--seconds', '4').to_i
  puts BRoll.estimate([ { seconds: seconds } ])[:line]
  exit if ARGV.include?('--estimate-only')

  WalkthroughEnv.load_secrets
  budget = BRoll::Budget.new(flag.call('--max-usd', BRoll::DEFAULT_CEILING_USD).to_f)
  puts BRoll.generate(source_image: image, prompt: prompt, seconds: seconds, cache_root: cache,
                      model: flag.call('--model', BRoll::MODEL), budget: budget)
  puts "spent about $#{format('%.2f', budget.spent)}"
end
