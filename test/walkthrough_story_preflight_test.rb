# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/walkthrough_render"
require_relative "../scripts/elevenlabs"
require_relative "enroll_helpers"

# The paid-call boundary: every entry that can spend money refuses a missing
# or broken story before its first paid call. Stub providers fail the test, or
# raise the Called sentinel, if reached.
class WalkthroughStoryPreflightTest < Minitest::Test
  include EnrollHelpers

  class Called < StandardError; end

  STORY = { "hero" => "an engineer", "audience" => "engineers",
            "before" => { "state" => "slow", "scenes" => [ "list" ] },
            "turn" => { "moment" => "a switch", "scenes" => [ "detail" ] },
            "after" => { "outcomes" => [ "fast" ], "scenes" => [ "hero" ] } }.freeze

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "screens"))
    %w[list detail hero].each { |n| File.write(File.join(@root, "screens", "#{n}.html"), "<html><body>#{n}</body></html>") }
    @calls = []
    enroll_home!({ "elevenlabs" => "sk_test_secret_value_123" })
  end

  def teardown
    FileUtils.rm_rf(@root)
    restore_home!
  end

  def scene(id, order)
    { "id" => id, "order" => order, "title" => id, "screen" => { "html" => "screens/#{id}.html" },
      "narration" => { "text" => "Scene #{id} speaks.", "measured_ms" => 0 },
      "assumptions" => [ { "id" => "A-0#{order}", "text" => "x" } ],
      "timing" => { "min_ms" => 1000, "pad_ms" => 200, "transition" => { "type" => "cut", "ms" => 0 } } }
  end

  def board(story: STORY)
    b = { "schema_version" => 1, "slug" => "demo", "title" => "Demo", "fps" => 30,
          "review" => { "kind" => "explainer", "audience" => "Engineers", "purpose" => [ "State what the demo shows" ] },
          "viewport" => { "w" => 640, "h" => 360, "dpr" => 1 },
          "voice" => { "voice_id" => "v1", "model" => "eleven_multilingual_v2", "output_format" => "mp3_44100_128" },
          "music" => { "model" => "music_v1", "prompt" => "calm", "gain_db" => -18 },
          "scenes" => [ scene("list", 1), scene("detail", 2), scene("hero", 3) ] }
    b["story"] = story if story
    b
  end

  def write(b)
    path = File.join(@root, "storyboard.json")
    File.write(path, JSON.pretty_generate(b))
    path
  end

  # Every provider that could spend or capture raises Called and records itself.
  def providers
    %i[tts music image broll roast browser capture lint].to_h do |name|
      [ name, ->(*_a, **_k, &_b) { @calls << name; raise Called, name.to_s } ]
    end.merge(free_bytes: ->(_root) { 1 << 50 })
  end

  def run_for(b, **opts)
    write(b)
    WalkthroughRender::Run.new(@root, providers: providers, out: (@out = StringIO.new), gates: { roast: false }, **opts)
  end

  def no_story_board = board(story: nil)

  def empty_after_scenes = board(story: STORY.merge("after" => { "outcomes" => [ "fast" ], "scenes" => [] }))

  # -- Run#call ---------------------------------------------------------------

  def test_call_with_a_valid_story_reaches_the_providers
    assert_raises(Called) { run_for(board).call }
    refute_empty @calls
  end

  def test_call_with_a_missing_story_refuses_before_any_provider
    err = assert_raises(WalkthroughStory::MissingStoryError) { run_for(no_story_board).call }
    assert_empty @calls
    out = StringIO.new
    assert_equal 2, WalkthroughStory.report(err, out: out)
    assert_includes out.string, "story: story is missing"
  end

  def test_call_with_empty_after_scenes_refuses_before_any_provider
    err = assert_raises(WalkthroughStory::MissingStoryError) { run_for(empty_after_scenes).call }
    assert_includes err.message, "story.after.scenes"
    assert_empty @calls
  end

  def test_estimate_only_with_a_missing_story_warns_and_buys_nothing
    assert_nil run_for(no_story_board).call(estimate_only: true)
    assert_empty @calls
    assert_match(/^warning: story: story is missing/, @out.string)
  end

  def test_estimate_only_with_a_valid_story_prints_no_story_warning
    run_for(board).call(estimate_only: true)
    refute_includes @out.string, "warning: story"
  end

  # -- silent_call ------------------------------------------------------------

  def test_silent_call_with_a_missing_story_refuses_before_broll
    assert_raises(WalkthroughStory::MissingStoryError) { run_for(no_story_board, silent: true, board: no_story_board).call }
    refute_includes @calls, :broll
    assert_empty @calls
  end

  # -- elevenlabs --------------------------------------------------------------

  def cli(*argv, transport:)
    out = StringIO.new
    code = ElevenLabs::Cli.run(argv.map(&:to_s) + [ "--cache", File.join(@root, ".cache") ], out: out, transport: transport, sleeper: ->(_s) { })
    [ code, out.string ]
  end

  Resp = Struct.new(:code, :body, :headers) do
    def [](name) = (headers || {})[name]
  end

  def tts_body
    JSON.generate("audio_base64" => Base64.strict_encode64("MP3DATA"),
                  "alignment" => { "characters" => %w[a], "character_start_times_seconds" => [ 0.0 ], "character_end_times_seconds" => [ 1.0 ] },
                  "normalized_alignment" => { "characters" => %w[H i], "character_start_times_seconds" => [ 0.0, 0.1 ],
                                              "character_end_times_seconds" => [ 0.1, 1.25 ] })
  end

  # Records the call and answers like the API; a refused story never reaches it.
  def spy_transport = ->(*_a) { @calls << :http; Resp.new(200, tts_body) }

  def test_narrate_storyboard_without_a_story_exits_2_and_never_calls_tts
    code, out = cli("narrate", "--storyboard", write(no_story_board), transport: spy_transport)
    assert_equal 2, code
    assert_includes out, "story: story is missing"
    assert_empty @calls
  end

  def test_music_storyboard_without_a_story_exits_2_and_never_calls_music
    code, out = cli("music", "--storyboard", write(no_story_board), transport: spy_transport)
    assert_equal 2, code
    assert_includes out, "run the story round"
    assert_empty @calls
  end

  def test_estimate_only_storyboard_skips_the_preflight
    code, out = cli("narrate", "--storyboard", write(no_story_board), "--estimate-only", transport: spy_transport)
    assert_equal 0, code, out
    assert_empty @calls
  end

  def test_narrate_text_input_is_not_a_walkthrough_and_skips_the_preflight
    code, out = cli("narrate", "--text", "Hi there", "--voice", "v1", transport: spy_transport)
    assert_equal 0, code, out
    assert_equal [ :http ], @calls
  end

  def test_narrate_storyboard_with_a_story_reaches_the_transport
    code, out = cli("narrate", "--storyboard", write(board), transport: spy_transport)
    assert_equal 0, code, out
    assert_equal [ :http, :http, :http ], @calls
  end
end
