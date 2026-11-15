# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "enroll_helpers"
require_relative "../scripts/walkthrough_env"

class WalkthroughEnvTest < Minitest::Test
  include EnrollHelpers

  def test_each_helper_reads_its_own_enrolled_key
    with_enrolled("openai", "elevenlabs", "gemini") do
      assert_equal "sk-test-secret", WalkthroughEnv.openai_key!
      assert_equal "el-test-secret", WalkthroughEnv.elevenlabs_key!
      assert_equal "gemini-test-secret", WalkthroughEnv.gemini_key!
    end
  end

  def test_env_var_alone_does_not_supply_a_key
    saved = ENV.fetch("OPENAI_API_KEY", nil)
    ENV["OPENAI_API_KEY"] = "sk-from-env"
    with_enrolled do
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key! }
      assert_kind_of WalkthroughEnv::MissingKeyError, err
      refute_includes err.full_message, "sk-from-env"
    end
  ensure
    saved.nil? ? ENV.delete("OPENAI_API_KEY") : ENV["OPENAI_API_KEY"] = saved
  end

  def test_enroll_prints_the_line_and_snippet_without_values_and_returns_4
    with_enrolled("elevenlabs") do
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key! }
      out = StringIO.new
      assert_equal 4, WalkthroughEnv.enroll(err, out: out)
      assert_one_enroll_line(out.string, "openai")
      assert_includes out.string, "Paste this for the user to run in their own terminal: ruby ~/.claude/cf/bin/cf_keys.rb enroll openai"
      refute_includes out.string, "el-test-secret"
      refute_includes out.string, "confirm-inherit"
    end
  end

  def test_enroll_names_confirm_inherit_when_an_ancestor_key_exists
    with_enrolled do
      parent = File.dirname(CfProjectIdentity.for(Dir.pwd).root)
      CfSecretStore.write_key(CfProjectIdentity.for_explicit_dir(parent).slug, "openai", "sk-parent")
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key! }
      out = StringIO.new
      WalkthroughEnv.enroll(err, out: out)
      assert_includes out.string, "AskUserQuestion"
      assert_includes out.string, "cf_keys.rb confirm-inherit openai"
      refute_includes out.string, "sk-parent"
    end
  end

  def test_enroll_exit_exits_4
    with_enrolled do
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.gemini_key! }
      exit_err = assert_raises(SystemExit) { WalkthroughEnv.enroll_exit!(err, out: StringIO.new) }
      assert_equal 4, exit_err.status
    end
  end
end
