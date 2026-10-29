# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast_video"
require_relative "imagegen_helpers"

class RoastVideoTest < Minitest::Test
  CRITIC = {
    "score" => 6, "summary" => "Narration runs ahead of the picture.",
    "issues" => [ { "priority" => "P1", "timestamp" => "00:42", "screen" => "inquiry", "problem" => "Says sent before the click",
                    "fix" => "Move the cue after the click" } ],
    "thirty_second_test" => { "verdict" => "partial", "reason" => "Buyer path unclear" },
    "purpose_test" => [ { "outcome" => "Buyer can name the next step", "verdict" => "partial", "reason" => "Cue lands early" } ]
  }.freeze

  class Http < ImagegenHelpers::FakeHttp
    def initialize(critic = CRITIC) = super("200").tap { @critic = critic }

    def request(req)
      @requests << req
      body = { "output" => [ { "content" => [ { "type" => "output_text", "text" => JSON.generate(@critic) } ] } ],
               "usage" => { "input_tokens" => 10, "output_tokens" => 5 } }
      ImagegenHelpers::FakeResponse.new("200", JSON.generate(body))
    end
  end

  # Stands in for the ffmpeg container: writes three frames into the /work mount.
  def fake_docker
    calls = []
    lambda do |argv|
      calls << argv
      work = argv.find { |a| a.to_s.end_with?("target=/work") }[/source=([^"]+)"/, 1]
      3.times { |i| File.write(File.join(work, format("%05d.jpg", i + 1)), "jpg#{i}") }
      [ "", Struct.new(:success?).new(true) ]
    end.tap { |l| l.define_singleton_method(:calls) { calls } }
  end

  def setup
    @dir = Dir.mktmpdir
    @mp4 = File.join(@dir, "walkthrough.mp4").tap { |p| File.write(p, "mp4") }
    File.write(File.join(@dir, "walkthrough.vtt"), "WEBVTT\n\n00:00.000 --> 00:02.000\nHello")
    @brief = File.join(@dir, "brief.md").tap { |p| File.write(p, "Label buyer") }
    @roast = File.join(@dir, "roast")
    FileUtils.mkdir_p(@roast)
    File.write(File.join(@roast, "round-2.json"), JSON.generate(CRITIC.merge("issues" => [])))
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    ENV.delete("CF_SECRETS_ENV")
  end

  def teardown
    ENV.delete("OPENAI_API_KEY")
    FileUtils.remove_entry(@dir)
  end


  def test_one_request_with_labelled_frames_transcript_and_timestamped_round
    docker = fake_docker
    out = StringIO.new
    http = Http.new
    code = RoastVideo::Cli.run([ "--video", @mp4, "--brief", @brief, "--out-dir", @roast, "--cache", File.join(@dir, ".cache") ],
                               out: out, http: http, docker: docker)
    assert_equal 0, code, out.string
    assert_match(/roast estimate: 1 call to gpt-6\.1-sol, 3 frame/, out.string)
    assert_equal 1, http.requests.size
    body = JSON.parse(http.requests.first.body)
    content = body["input"][1]["content"]
    assert_equal %w[[00:00] [00:00] [00:01]], content.select { |c| c["text"]&.start_with?("[") }.map { |c| c["text"] }
    assert_equal 3, content.count { |c| c["type"] == "input_image" }
    assert_includes content.first["text"], "Hello"
    assert_includes content.first["text"], "Round 2 (stills) critic"
    assert_includes body["text"]["format"]["schema"]["properties"]["issues"]["items"]["required"], "timestamp"
    refute_includes http.requests.first.body, "sk-test-secret"
    assert_match(/\[00:42\]/, File.read(File.join(@roast, "round-2.video.md")))
    assert File.file?(File.join(@roast, "round-2.video.json"))
    assert_equal [ 2 ], Roast.load_history(@roast).map { |h| h[:round] }

    again = StringIO.new
    RoastVideo::Cli.run([ "--video", @mp4, "--brief", @brief, "--out-dir", @roast, "--cache", File.join(@dir, ".cache"), "--round", "2" ],
                        out: again, http: Http.new, docker: docker)
    refute_match(/cached/, again.string) # history now includes the video round, so a new key
    assert_equal 1, docker.calls.size, "frames are cached by MP4 digest"
  end

  def test_ceiling_refuses_before_any_request
    http = Http.new
    out = StringIO.new
    code = RoastVideo::Cli.run([ "--video", @mp4, "--brief", @brief, "--out-dir", @roast, "--cache", File.join(@dir, ".cache"),
                                 "--max-usd", "0.001" ], out: out, http: http, docker: fake_docker)
    assert_equal 1, code
    assert_match(/ceiling/, out.string)
    assert_empty http.requests
  end

  def test_bad_timestamp_is_rejected
    body = { "output" => [ { "content" => [ { "type" => "output_text",
                                              "text" => JSON.generate(CRITIC.merge("issues" => [ CRITIC["issues"][0].merge("timestamp" => "soon") ])) } ] } ] }
    assert_raises(Roast::RequestError) { RoastVideo.parse_critic(body) }
  end

  def test_roast_cli_routes_video_flag
    assert_equal 2, Roast::Cli.run([ "--video", @mp4 ], out: StringIO.new)
  end
end
