# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_env"

class WalkthroughEnvTest < Minitest::Test
  VARS = %w[ELEVEN_LABS_API_KEY ELEVENLABS_API_KEY OPENAI_API_KEY CF_SECRETS_ENV WT_PLAIN WT_QUOTED WT_SINGLE].freeze

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
    err = assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.elevenlabs_key! }
    assert_equal "ELEVEN_LABS_API_KEY (or ELEVENLABS_API_KEY) not set; set it or point CF_SECRETS_ENV at an env file",
                 err.message
    err = assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.openai_key! }
    assert_match(/\AOPENAI_API_KEY not set/, err.message)
  end

  def test_key_value_never_appears_in_error_text
    secret = "sk-very-secret-value-123"
    ENV["ELEVEN_LABS_API_KEY"] = secret
    ENV["OPENAI_API_KEY"] = ""
    err = assert_raises(WalkthroughEnv::MissingKeyError) { WalkthroughEnv.openai_key! }
    refute_includes err.message, secret
    refute_includes err.full_message, secret
  end
end
