# frozen_string_literal: true

require "fileutils"

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

    # tags: source basename => recording tag (default: the basename's stem).
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

      @last = @tags.fetch(base, File.basename(base, ".*"))
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
      File.binwrite(File.join(host, File.basename(argv.last)), "fixed #{argv.last}")
      tag(input(argv))
      [ "", Status.new(true) ]
    end
  end

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
