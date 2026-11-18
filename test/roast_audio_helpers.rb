# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

# A stand-in for the FFmpeg container in cf:roast --audio tests. It answers
# each docker argv with the output the real pinned image printed for the same
# fixture (test/fixtures/roast_audio/recorded/<tag>.<kind>), and on an encode
# writes a placeholder file to the /out mount. A gate output (src-*.aN.mp3) is
# answered with the <tag>.fixed recordings of the source last repaired.
module RoastAudioHelpers
  FIXTURES = File.expand_path("fixtures/roast_audio", __dir__)
  RECORDED = File.join(FIXTURES, "recorded")

  Status = Struct.new(:success?)

  class FakeDocker
    attr_reader :calls

    # tags: source basename => recording tag (default: the basename's stem, or
    # the Hash's own default, so a test can answer every take alike).
    # edits: "<tag>.<kind>" => ->(text) { new_text }, to craft a case from a recording.
    def initialize(tags: {}, edits: {}, down: false)
      @tags = tags
      @edits = edits
      @down = down
      @calls = []
      @last = nil
    end

    def call(argv)
      @calls << argv
      return [ "docker: Cannot connect to the Docker daemon", Status.new(false) ] if @down

      kind = kind(argv)
      return encode(argv) if kind == :encode

      [ answer(tag(input(argv)), kind), Status.new(true) ]
    end

    def kinds = @calls.map { |a| kind(a) }

    def joined(kind) = @calls.select { |a| kind(a) == kind }.map { |a| a.join(" ") }

    private

    def kind(argv)
      text = argv.join(" ")
      return :probe if text.include?("--entrypoint ffprobe")
      return :rms if text.include?("ametadata")
      return :loudnorm if text.include?("print_format=json")
      return :encode if text.include?("libmp3lame")

      :analysis
    end

    def input(argv) = File.basename(argv.include?("-i") ? argv[argv.index("-i") + 1] : argv.last)

    def tag(base)
      return "#{@last}.fixed" if base.match?(/\.a\d+\.mp3\z/)

      @last = @tags[base] || File.basename(base, ".*")
    end

    def answer(tag, kind)
      ext = kind == :probe ? "probe.json" : "#{kind}.txt"
      key = "#{tag}.#{ext}"
      text = File.read(File.join(RECORDED, key))
      (@edits[key] || ->(t) { t }).call(text)
    end

    def encode(argv)
      host = argv.join(" ")[/source=([^"]*)",target=\/out/, 1]
      FileUtils.mkdir_p(host)
      # Same source, same bytes, as FFmpeg's encode is deterministic.
      File.binwrite(File.join(host, File.basename(argv.last)), "fixed #{tag(input(argv))} #{Digest::SHA256.hexdigest(argv[0..-2].join(' '))}")
      [ "", Status.new(true) ]
    end
  end

  CUE_TEXT = [ "The first cue sits inside the tone.", "The second cue continues with no pause.", "The third cue ends where the tone ends." ].freeze

  # continuous.vtt's text, timed exactly to its cues.
  def exact_spans = CUE_TEXT.zip([ [ 250, 2000 ], [ 2000, 4000 ], [ 4000, 5750 ] ]).map { |t, (s, e)| [ t, s, e ] }

  # ElevenLabs-shaped alignment: words spread evenly over each [text, start_ms, end_ms] span.
  def alignment(spans)
    chars = []
    starts = []
    ends = []
    spans.each_with_index do |(text, s, e), n|
      words = text.split
      step = (e - s) / words.size.to_f
      words.each_with_index do |w, i|
        ws = s + (i * step)
        w.each_char.with_index do |ch, k|
          chars << ch
          starts << ((ws + (k * step / w.size)) / 1000.0)
          ends << ((ws + ((k + 1) * step / w.size)) / 1000.0)
        end
        next if n == spans.size - 1 && i == words.size - 1

        chars << " "
        starts << ends.last
        ends << ends.last
      end
    end
    { "characters" => chars, "character_start_times_seconds" => starts, "character_end_times_seconds" => ends }
  end

  # A sidecar binding an alignment to the audio with this digest.
  def write_sidecar(path, spans, audio_sha)
    a = alignment(spans)
    File.write(path, JSON.generate({ "audio_sha256" => audio_sha, "alignment_sha256" => RoastAudioWords.sha256(a),
                                     "generator" => { "provider" => "elevenlabs", "voice_id" => "v", "model" => "m", "request_key" => "k" }, "alignment" => a }))
    path
  end

  # A bound sidecar for a staged copy of continuous.mp3, beside it.
  def bound_sidecar(audio) = write_sidecar(audio.sub(/\.mp3\z/, ".alignment.json"), exact_spans, Digest::SHA256.file(audio).hexdigest)

  # Copies a fixture clip and its captions into dir (optionally renamed).
  def stage_clip(dir, name, as: name)
    FileUtils.mkdir_p(dir)
    audio = File.join(dir, "#{as}.mp3")
    FileUtils.cp(File.join(FIXTURES, "#{name}.mp3"), audio)
    vtt = File.join(FIXTURES, "#{name}.vtt")
    FileUtils.cp(vtt, File.join(dir, "#{as}.vtt"))
    audio
  end
end
