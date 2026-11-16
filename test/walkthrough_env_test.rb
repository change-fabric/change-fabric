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

  def test_expired_key_exits_4_with_reason_expired_and_both_commands
    with_enrolled("openai") do
      slug = CfProjectIdentity.for(Dir.pwd).slug
      CfSecretStore.update_enrollment(slug, "openai", "expires_at" => "2000-01-01T00:00:00Z", "label" => "ci")
      err = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key! }
      out = StringIO.new
      assert_equal 4, WalkthroughEnv.enroll(err, out: out)
      assert_one_enroll_line(out.string, "openai")
      assert_equal "expired", enroll_lines(out.string).first.dig("cf_enroll", "reason")
      assert_includes out.string, 'key "ci" enrolled at'
      assert_includes out.string, "cf_keys.rb expires openai YYYY-MM-DD"
      refute_includes out.string, "sk-test-secret"
    end
  end

  def slug_here = CfProjectIdentity.for(Dir.pwd).slug

  # key! order, step 1: an active deferral exits 5 with one note before any
  # resolve, so even an enrolled key is never read.
  def test_active_deferral_exits_5_before_any_resolve
    with_enrolled("openai") do
      CfSecretStore.defer(slug_here, "openai")
      err = StringIO.new
      calls = []
      original = CfSecrets.method(:resolve)
      CfSecrets.define_singleton_method(:resolve) { |*args, **kw| calls << args && original.call(*args, **kw) }
      begin
        exit_err = assert_raises(WalkthroughEnv::Deferred) { WalkthroughEnv.key!("openai", err: err) }
      ensure
        CfSecrets.define_singleton_method(:resolve, original)
      end
      assert_equal 5, exit_err.status
      assert_kind_of SystemExit, exit_err
      assert_empty calls
      assert_equal 1, err.string.lines.size
      assert_match(/\A\[cf\] openai deferred until \d{4}-\d{2}-\d{2}T\S+; skipping paid step\n\z/, err.string)
    end
  end

  def test_lapsed_deferral_falls_through_to_missing_exit_4
    with_enrolled do
      CfSecretStore.defer(slug_here, "openai", days: 1, now: Time.now - (2 * 86_400))
      err = StringIO.new
      e = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.key!("openai", err: err) }
      assert_equal "missing", e.to_h[:reason]
      assert_empty err.string
    end
  end

  def test_expired_exits_4_without_a_warning_line
    with_enrolled("openai") do
      CfSecrets.reset_warnings!
      CfSecretStore.update_enrollment(slug_here, "openai", "expires_at" => "2000-01-01T00:00:00Z")
      err = StringIO.new
      e = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.key!("openai", err: err) }
      assert_equal "expired", e.to_h[:reason]
      assert_empty err.string
    end
  end

  def test_warn_window_prints_exactly_one_line_across_two_calls
    with_enrolled("openai") do
      CfSecrets.reset_warnings!
      soon = (Time.now.utc + 3600).iso8601
      CfSecretStore.update_enrollment(slug_here, "openai", "expires_at" => soon)
      err = StringIO.new
      2.times { assert_equal "sk-test-secret", WalkthroughEnv.key!("openai", err: err) }
      assert_equal 1, err.string.lines.size
      assert_includes err.string, "(within 24h); renew: ruby ~/.claude/cf/bin/cf_keys.rb enroll openai"
    ensure
      CfSecrets.reset_warnings!
    end
  end

  def test_ok_key_prints_nothing
    with_enrolled("openai") do
      CfSecrets.reset_warnings!
      CfSecretStore.update_enrollment(slug_here, "openai", "expires_at" => "2999-01-01")
      err = StringIO.new
      assert_equal "sk-test-secret", WalkthroughEnv.key!("openai", err: err)
      assert_empty err.string
    end
  end
end
