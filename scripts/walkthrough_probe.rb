# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'change_docker'
require_relative 'path_canon'

# Reports a draft's duration, frame count, and streams. FFmpeg and ffprobe
# are not on the host, so ffprobe runs in the already-pinned FFmpeg image,
# offline, with the file's directory mounted read-only.
#
#   ruby walkthrough_probe.rb walkthrough/<slug>/<slug>-draft-03.mp4 [--json]
module WalkthroughProbe
  class ProbeError < StandardError; end

  MOUNT = '/probe'

  module_function

  # The docker argv. -count_packets fills nb_read_packets, the frame count
  # when a stream does not declare nb_frames.
  def command(path)
    real = PathCanon.real(path)
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, entrypoint: 'ffprobe',
                             mounts: { File.dirname(real) => { target: MOUNT, readonly: true } },
                             args: [ '-v', 'error', '-count_packets', '-print_format', 'json', '-show_format', '-show_streams',
                                     File.join(MOUNT, File.basename(real)) ], user: :host)
  end

  # runner takes the argv and returns [output, success].
  def probe(path, runner: method(:run))
    raise ProbeError, "no such file: #{path}" unless File.file?(path)

    out, ok = runner.call(command(path))
    raise ProbeError, "ffprobe failed: #{out.to_s.strip}" unless ok

    summarize(out)
  rescue JSON::ParserError => e
    raise ProbeError, "ffprobe output is not JSON: #{e.message}"
  end

  # Stdout only: docker prints platform warnings on stderr, which would
  # break the JSON. On failure stderr is the message.
  def run(argv)
    out, err, status = Open3.capture3(*argv)
    [ status.success? ? out : err, status.success? ]
  end

  def summarize(json)
    data = JSON.parse(json)
    streams = Array(data['streams']).map { |s| stream(s) }
    video = streams.find { |s| s[:type] == 'video' }
    { duration_s: number(data.dig('format', 'duration')), frames: video&.dig(:frames), fps: video&.dig(:fps), streams: streams }
  end

  def stream(raw)
    { index: raw['index'], type: raw['codec_type'], codec: raw['codec_name'], width: raw['width'], height: raw['height'],
      fps: rate(raw['avg_frame_rate']), frames: integer(raw['nb_frames']) || integer(raw['nb_read_packets']),
      sample_rate: integer(raw['sample_rate']), channels: raw['channels'], duration_s: number(raw['duration']) }
  end

  def lines(summary)
    out = [ format('duration: %.3fs', summary[:duration_s].to_f) ]
    out << format('frames: %<n>d at %<f>.2f fps', n: summary[:frames], f: summary[:fps].to_f) if summary[:frames]
    out + summary[:streams].map { |s| "stream #{s[:index]}: #{describe(s)}" }
  end

  def describe(s)
    parts = [ "#{s[:type]} #{s[:codec]}" ]
    parts[0] += " #{s[:width]}x#{s[:height]}" if s[:width]
    parts[0] += format(' %.2f fps', s[:fps]) if s[:type] == 'video' && s[:fps]
    parts[0] += " #{s[:sample_rate]} Hz #{s[:channels]} ch" if s[:sample_rate]
    parts << "#{s[:frames]} frames" if s[:type] == 'video' && s[:frames]
    parts << format('%.3fs', s[:duration_s]) if s[:duration_s]
    parts.join(', ')
  end

  def rate(text)
    num, den = text.to_s.split('/').map { |x| Float(x, exception: false) }
    num && den&.positive? ? num / den : nil
  end

  def number(text) = Float(text.to_s, exception: false)

  def integer(text) = Integer(text.to_s, exception: false)
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV.find { |a| !a.start_with?('--') } or abort('usage: walkthrough_probe.rb <file.mp4> [--json]')
  begin
    summary = WalkthroughProbe.probe(path)
    puts(ARGV.include?('--json') ? JSON.pretty_generate(summary) : WalkthroughProbe.lines(summary))
  rescue WalkthroughProbe::ProbeError => e
    abort("walkthrough_probe: #{e.message}")
  end
end
