# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "stringio"
require "tmpdir"
require_relative "enroll_helpers"
require_relative "key_project_helpers"
require_relative "../scripts/elevenlabs"

# End to end, offline: a fake key store (HOME in a tmpdir) with a stub key
# enrolled for a temp git repo, a paid entrypoint run with its cwd inside a
# fake scratchpad, the network stubbed at the transport. No real key is read
# and no paid call is made.
class KeyProjectE2ETest < Minitest::Test
  include EnrollHelpers
  include KeyProjectHelpers

  STUB_KEY = "el-stub-key-for-the-repo"
  Resp = Struct.new(:code, :body, :headers) do
    def [](name) = (headers || {})[name]
  end

  def setup
    @home_cwd = Dir.pwd
    enroll_home!
    @scratch = make_scratchpad!
    @repo = make_repo!(File.join(@kp_tmp, "app"))
    CfSecretStore.write_key(CfProjectIdentity.for(@repo).slug, "elevenlabs", STUB_KEY)
    @cache = File.join(@kp_tmp, "cache")
    @keys = []
    @transport = lambda do |_req, key|
      @keys << key
      Resp.new("200", "MUSIC")
    end
  end

  def teardown
    Dir.chdir(@home_cwd)
    remove_scratchpad!
    restore_home!
  end

  def music(*extra)
    out = StringIO.new
    code = Dir.chdir(@scratch) do
      ElevenLabs::Cli.run([ "music", "--prompt", "calm", "--duration-ms", "30000", "--cache", @cache, *extra ],
                          out: out, transport: @transport, sleeper: ->(_) { })
    end
    [ code, out.string ]
  end

  def test_scratchpad_run_with_project_uses_the_repos_key
    code, text = music("--project", @repo)
    assert_equal 0, code, text
    assert_equal [ STUB_KEY ], @keys
    refute_includes text, STUB_KEY
    assert_empty enroll_lines(text)
  end

  def test_scratchpad_run_with_project_equals_form_uses_the_repos_key
    code, text = music("--project=#{@repo}")
    assert_equal 0, code, text
    assert_equal [ STUB_KEY ], @keys
  end

  def test_scratchpad_run_without_project_is_loud_exit_4_and_makes_no_call
    code, text = music
    assert_equal 4, code
    assert_empty @keys
    assert_empty enroll_lines(text)
    assert_includes text, @scratch
    assert_includes text, "session record"
    assert_includes text, "Fix: re-run with --project <repo root>"
  end

  def test_project_naming_the_scratchpad_exits_2_and_makes_no_call
    code, text = music("--project", @scratch)
    assert_equal 2, code
    assert_empty @keys
    assert_empty enroll_lines(text)
    assert_includes text, @scratch
  end

  def test_a_repo_cwd_without_the_flag_is_unchanged
    out = StringIO.new
    code = Dir.chdir(@repo) do
      ElevenLabs::Cli.run([ "music", "--prompt", "calm", "--duration-ms", "30000", "--cache", @cache ],
                          out: out, transport: @transport, sleeper: ->(_) { })
    end
    assert_equal 0, code, out.string
    assert_equal [ STUB_KEY ], @keys
  end

  def test_cached_music_replays_from_a_scratchpad_without_a_project
    assert_equal 0, music("--project", @repo).first
    @keys.clear
    code, text = music
    assert_equal 0, code, text
    assert_empty @keys
  end

  def test_cached_narration_replays_from_a_scratchpad_without_a_project
    body = JSON.generate("audio_base64" => Base64.strict_encode64("MP3"),
                         "alignment" => { "characters" => %w[a], "character_start_times_seconds" => [ 0.0 ],
                                          "character_end_times_seconds" => [ 1.0 ] })
    transport = lambda do |_req, key|
      @keys << key
      Resp.new("200", body)
    end
    run = lambda do |*extra|
      Dir.chdir(@scratch) do
        ElevenLabs::Cli.run([ "narrate", "--text", "Hi", "--voice", "v1", "--cache", @cache, *extra ],
                            out: StringIO.new, transport: transport, sleeper: ->(_) { })
      end
    end
    assert_equal 0, run.call("--project", @repo)
    @keys.clear
    assert_equal 0, run.call
    assert_empty @keys
  end
end
