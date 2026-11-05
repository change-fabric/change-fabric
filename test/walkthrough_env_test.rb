# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_env"
require_relative "enroll_helpers"

class WalkthroughEnvTest < Minitest::Test
  include EnrollHelpers

  VARS = %w[ELEVEN_LABS_API_KEY ELEVENLABS_API_KEY OPENAI_API_KEY GEMINI_API_KEY CF_SECRETS_ENV WT_PLAIN WT_QUOTED WT_SINGLE].freeze

  def setup
    @saved = VARS.to_h { |v| [ v, ENV.fetch(v, nil) ] }
    VARS.each { |v| ENV.delete(v) }
    @dir = Dir.mktmpdir
  end

  def teardown
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    FileUtils.rm_rf(@dir)
  end

  def write_env(body)
    path = File.join(@dir, ".env")
    File.write(path, body)
    path
  end

  def test_parses_plain_quoted_and_comment_lines
    path = write_env(<<~ENV)
      # a comment
      WT_PLAIN=abc
      export WT_QUOTED="two words"
      WT_SINGLE='x=y'

      not a line
    ENV
    WalkthroughEnv.load_secrets(path)
    assert_equal "abc", ENV.fetch("WT_PLAIN")
    assert_equal "two words", ENV.fetch("WT_QUOTED")
    assert_equal "x=y", ENV.fetch("WT_SINGLE")
  end

  def test_does_not_override_a_set_var
    ENV["WT_PLAIN"] = "from-shell"
    WalkthroughEnv.load_secrets(write_env("WT_PLAIN=from-file\n"))
    assert_equal "from-shell", ENV.fetch("WT_PLAIN")
  end

  def test_missing_file_is_silent
    assert_nil WalkthroughEnv.load_secrets(File.join(@dir, "nope.env"))
  end

  def test_default_path_follows_cf_secrets_env
    ENV["CF_SECRETS_ENV"] = write_env("OPENAI_API_KEY=sk-file\n")
    WalkthroughEnv.load_secrets
    assert_equal "sk-file", WalkthroughEnv.openai_key!
  end

  def test_unset_cf_secrets_env_loads_nothing
    assert_nil WalkthroughEnv.load_secrets
    refute_includes WalkthroughEnv.constants, :DEFAULT_SECRETS_PATH
  end

  def test_elevenlabs_primary_name_wins
    ENV["ELEVEN_LABS_API_KEY"] = "primary"
    ENV["ELEVENLABS_API_KEY"] = "fallback"
    assert_equal "primary", WalkthroughEnv.elevenlabs_key!
  end

  def test_elevenlabs_fallback_name
    ENV["ELEVENLABS_API_KEY"] = "fallback"
    assert_equal "fallback", WalkthroughEnv.elevenlabs_key!
  end

  def test_named_error_messages
    with_store(enrolled: true) do
      err = assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.elevenlabs_key! }
      assert_equal "ELEVEN_LABS_API_KEY for elevenlabs not found in the process env", err.message
      err = assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.openai_key! }
      assert_match(/\AOPENAI_API_KEY for openai not found/, err.message)
      refute_kind_of WalkthroughEnv::NeedsEnrollment, err
    end
  end

  def test_unenrolled_project_needs_enrollment_and_is_a_missing_key_error
    with_store do
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.elevenlabs_key! }
      assert_kind_of WalkthroughEnv::MissingKeyError, err
      assert_equal "ELEVEN_LABS_API_KEY", err.to_h[:env_var]
      assert_equal CfSecrets.project_key, err.to_h[:project_key]
    end
  end

  def test_enroll_prints_one_line_without_values_and_returns_4
    secret = "sk-sentinel-never-printed"
    path = write_env("UNRELATED=#{secret}\n")
    with_store do
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key! }
      out = StringIO.new
      assert_equal 4, WalkthroughEnv.enroll(err, out: out)
      assert_one_enroll_line(out.string, "openai")
      refute_includes out.string, secret
      refute_includes out.string, path
    end
  end

  def test_enroll_exit_exits_4
    with_store do
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.gemini_key! }
      exit_err = assert_raises(SystemExit) { WalkthroughEnv.enroll_exit!(err, out: StringIO.new) }
      assert_equal 4, exit_err.status
    end
  end

  def test_recorded_env_file_supplies_the_key_without_touching_env
    path = write_env("OPENAI_API_KEY=from-file\n")
    with_store do
      store = CfSecrets.store_path(Dir.home)
      FileUtils.mkdir_p(File.dirname(store))
      File.write(store, YAML.dump("projects" => { CfSecrets.project_key => { "env_file" => path } }))
      assert_equal "from-file", WalkthroughEnv.openai_key!
      assert_nil ENV.fetch("OPENAI_API_KEY", nil)
    end
  end

  def test_key_value_never_appears_in_error_text
    secret = "sk-very-secret-value-123"
    ENV["ELEVEN_LABS_API_KEY"] = secret
    ENV["OPENAI_API_KEY"] = ""
    err = with_store { assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.openai_key! } }
    refute_includes err.message, secret
    refute_includes err.full_message, secret
  end

  def test_gemini_key_reads_env_and_names_the_variable_when_missing
    err = with_store(enrolled: true) { assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.gemini_key! } }
    assert_match(/\AGEMINI_API_KEY for gemini not found/, err.message)
    ENV["GEMINI_API_KEY"] = "g-file"
    assert_equal "g-file", WalkthroughEnv.gemini_key!
  end
end
