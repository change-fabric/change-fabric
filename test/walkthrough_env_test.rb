# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "enroll_helpers"
require_relative "key_project_helpers"
require_relative "../scripts/key_project"
require_relative "../scripts/walkthrough_env"

class WalkthroughEnvTest < Minitest::Test
  include EnrollHelpers
  include KeyProjectHelpers

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

  # --- the key is looked up against the cwd the script resolved ---

  def with_project_keys(provider, &)
    with_enrolled do
      repo = make_repo!(File.join(Dir.mktmpdir, "app"))
      CfSecretStore.write_key(CfProjectIdentity.for(repo).slug, provider, "sk-repo")
      yield repo
    end
  end

  def test_each_helper_takes_the_key_from_the_cwd_it_is_given
    with_project_keys("openai") do |repo|
      assert_equal "sk-repo", WalkthroughEnv.openai_key!(cwd: repo)
      assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key! }
      assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.elevenlabs_key!(cwd: repo) }
      assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.gemini_key!(cwd: repo) }
    end
  end

  def test_a_projects_own_key_wins_over_an_ancestor
    with_project_keys("openai") do |repo|
      CfSecretStore.write_key(CfProjectIdentity.for_explicit_dir(File.dirname(repo)).slug, "openai", "sk-ancestor")
      assert_equal "sk-repo", WalkthroughEnv.openai_key!(cwd: repo)
    end
  end

  def test_defer_check_reads_the_given_cwd_not_the_process_cwd
    with_project_keys("openai") do |repo|
      CfSecretStore.defer(CfProjectIdentity.for(repo).slug, "openai")
      err = StringIO.new
      assert_raises(WalkthroughEnv::Deferred) { WalkthroughEnv.key!("openai", cwd: repo, err: err) }
      assert_includes err.string, "openai deferred until"
      assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.key!("openai", err: StringIO.new) }
    end
  end

  def test_revoked_reports_the_given_cwd_and_its_owning_level
    with_project_keys("openai") do |repo|
      failure = CfProviderError::AuthRevoked.new("rejected", provider: "openai", status: 401, next_step: "enroll")
      out = StringIO.new
      assert_equal 4, WalkthroughEnv.key_error(failure, out: out, cwd: repo)
      line = JSON.parse(out.string.lines.first).fetch("cf_enroll")
      assert_equal CfProjectIdentity.for(repo).root, line["project_root"]
      assert_equal "revoked", line["reason"]
      assert_includes out.string, "enrolled at #{CfProjectIdentity.for(repo).root}"
    end
  end

  # --- a scratchpad is never enrolled ---

  def test_enroll_for_an_unresolved_scratchpad_prints_the_fix_and_no_cf_enroll_line
    scratch = make_scratchpad!
    err = KeyProject::Unresolved.new(cwd: scratch, session: "sid-1")
    out = StringIO.new
    assert_equal 4, WalkthroughEnv.enroll(err, out: out)
    assert_empty enroll_lines(out.string)
    refute_includes out.string, "cf_keys.rb enroll"
    assert_includes out.string, scratch
    assert_includes out.string, "session record for sid-1"
    assert_includes out.string, "--project <repo root>"
  ensure
    remove_scratchpad!
  end

  def test_a_key_lookup_run_in_a_scratchpad_cwd_gets_the_fix_not_an_enroll_prompt
    scratch = make_scratchpad!
    with_enrolled do
      e = assert_raises(WalkthroughEnv::NeedsEnrollment) { WalkthroughEnv.openai_key!(cwd: scratch) }
      out = StringIO.new
      assert_equal 4, WalkthroughEnv.enroll(e, out: out)
      assert_empty enroll_lines(out.string)
      refute_includes out.string, "Paste this"
      assert_includes out.string, "Fix: re-run with --project <repo root>"
    end
  ensure
    remove_scratchpad!
  end
end
