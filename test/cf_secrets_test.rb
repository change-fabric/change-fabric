# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/cf_secrets"

class CfSecretsTest < Minitest::Test
  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV.fetch("HOME", nil)
    ENV["HOME"] = @home
    @org = File.join(@home, "org")
    @team = File.join(@org, "team")
    @project = File.join(@team, "proj")
    FileUtils.mkdir_p(@project)
    @err = StringIO.new
    CfSecrets.reset_warnings!
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
    CfSecrets.reset_warnings!
  end

  def enroll_at(dir, key, provider = "openai")
    CfSecretStore.write_key(CfProjectIdentity.for_explicit_dir(dir).slug, provider, key)
  end

  def confirm(provider, ancestor)
    slug = CfProjectIdentity.for(@project).slug
    CfSecretStore.update_meta(slug) { |m| (m["confirmed_inherits"] ||= {})[provider] = "dir:#{ancestor}" }
  end

  def resolve(provider = "openai", env: {})
    CfSecrets.resolve(provider, cwd: @project, env: env, err: @err)
  end

  def test_env_var_is_ignored_with_one_warning_naming_it_but_not_its_value
    env = { "OPENAI_API_KEY" => "sk-env-value-never-shown", "CF_SECRETS_ENV" => "/tmp/x.env" }
    err = assert_raises(CfSecrets::Unenrolled) { resolve(env: env) }
    assert_raises(CfSecrets::Unenrolled) { resolve(env: env) }
    assert_equal 1, @err.string.scan("ignoring OPENAI_API_KEY").size
    assert_equal 1, @err.string.scan("ignoring CF_SECRETS_ENV").size
    refute_includes @err.string, "sk-env-value-never-shown"
    refute_includes @err.string, "/tmp/x.env"
    assert_includes @err.string, "cf_keys.rb enroll openai"
    assert_equal "openai", err.provider
    assert_equal @project, err.root
  end

  def test_old_secrets_yml_pointers_are_ignored
    env_file = File.join(@home, "keys.env")
    File.write(env_file, "OPENAI_API_KEY=from-file\n")
    FileUtils.mkdir_p(File.join(@home, ".claude", "cf"))
    File.write(File.join(@home, ".claude", "cf", "secrets.yml"), "default: #{env_file}\n")
    assert_raises(CfSecrets::Unenrolled) { resolve }
  end

  def test_own_key_resolves
    enroll_at(@project, "own")
    assert_equal "own", resolve
  end

  def test_own_key_wins_over_a_confirmed_ancestor
    enroll_at(@project, "own")
    enroll_at(@org, "org")
    confirm("openai", @org)
    assert_equal "own", resolve
  end

  def test_ancestor_without_confirmation_is_unenrolled_with_an_inherit_hint
    enroll_at(@org, "org")
    err = assert_raises(CfSecrets::Unenrolled) { resolve }
    assert_equal @org, err.inheritable_from
    assert_equal @org, err.to_h[:inheritable_from]
  end

  def test_confirmed_ancestor_resolves
    enroll_at(@org, "org")
    confirm("openai", @org)
    assert_equal "org", resolve
  end

  def test_deepest_ancestor_wins_and_needs_its_own_confirmation
    enroll_at(@org, "org")
    enroll_at(@team, "team")
    confirm("openai", @org)
    err = assert_raises(CfSecrets::Unenrolled) { resolve }
    assert_equal @team, err.inheritable_from
    confirm("openai", @team)
    assert_equal "team", resolve
  end

  def test_confirmation_is_per_provider
    enroll_at(@org, "org", "gemini")
    confirm("openai", @org)
    assert_raises(CfSecrets::Unenrolled) { resolve("gemini") }
  end

  def test_unenrolled_details_carry_no_key_value
    enroll_at(@org, "org-secret-value")
    err = assert_raises(CfSecrets::Unenrolled) { resolve }
    refute_includes CfSecrets.enrollment_line(err), "org-secret-value"
    assert_includes err.snippet, "cf_keys.rb enroll openai --dir #{@project}"
    assert_equal "missing", err.to_h[:reason]
  end

  NOW = Time.utc(2026, 11, 15, 12, 0, 0)

  def set_entry(dir, fields, provider = "openai")
    CfSecretStore.update_enrollment(CfProjectIdentity.for_explicit_dir(dir).slug, provider, fields)
  end

  def resolve_at(now, provider = "openai")
    CfSecrets.resolve(provider, cwd: @project, env: {}, err: @err, now: now)
  end

  def test_tree_scoped_ancestor_resolves_without_confirmation
    enroll_at(@org, "org")
    set_entry(@org, "scope" => "tree")
    assert_equal "org", resolve
  end

  def test_tree_scope_is_per_provider_and_own_key_still_wins
    enroll_at(@org, "org")
    enroll_at(@org, "org-gem", "gemini")
    set_entry(@org, "scope" => "tree")
    assert_raises(CfSecrets::Unenrolled) { resolve("gemini") }
    enroll_at(@project, "own")
    assert_equal "own", resolve
  end

  def test_a_deeper_project_scoped_level_blocks_a_tree_scoped_one_above
    enroll_at(@org, "org")
    set_entry(@org, "scope" => "tree")
    enroll_at(@team, "team")
    err = assert_raises(CfSecrets::Unenrolled) { resolve }
    assert_equal @team, err.inheritable_from
    confirm("openai", @team)
    assert_equal "team", resolve
  end

  def test_confirm_inherit_still_works_beside_tree_scope
    enroll_at(@org, "org")
    confirm("openai", @org)
    set_entry(@org, "scope" => "project")
    assert_equal "org", resolve
  end

  def test_within_24h_warns_once_with_label_and_still_resolves
    enroll_at(@project, "own")
    set_entry(@project, "expires_at" => "2026-11-16T06:00:00Z", "label" => "billing")
    assert_equal "own", resolve_at(NOW)
    assert_equal "own", resolve_at(NOW)
    assert_equal 1, @err.string.scan("within 24h").size
    assert_includes @err.string, 'openai key "billing" enrolled at'
    assert_includes @err.string, "cf_keys.rb enroll openai --dir #{@project}"
    refute_includes @err.string, "own\n"
  end

  def test_more_than_24h_out_is_silent
    enroll_at(@project, "own")
    set_entry(@project, "expires_at" => "2026-11-17T00:00:00Z")
    assert_equal "own", resolve_at(NOW)
    assert_empty @err.string
  end

  def with_read_key_spy(spy)
    original = CfSecretStore.method(:read_key)
    CfSecretStore.define_singleton_method(:read_key) { |*| spy.call }
    yield
  ensure
    CfSecretStore.define_singleton_method(:read_key, original)
  end

  def test_expired_own_key_is_refused_before_it_is_read
    enroll_at(@project, "own-secret-value")
    set_entry(@project, "expires_at" => "2026-11-15T00:00:00Z", "label" => "billing")
    read = false
    with_read_key_spy(-> { read = true }) do
      err = assert_raises(CfSecrets::Expired) { resolve_at(NOW) }
      h = err.to_h
      assert_equal "expired", h[:reason]
      assert_equal @project, h[:owner_root]
      assert_equal "billing", h[:label]
      assert_equal "2026-11-15T00:00:00Z", h[:expires_at]
      assert_includes h[:snippet], "cf_keys.rb enroll openai --dir #{@project}"
      assert_includes h[:correct], "cf_keys.rb expires openai YYYY-MM-DD --dir #{@project}"
      assert_match(/expired at/, err.message)
      refute_includes CfSecrets.enrollment_line(err), "own-secret-value"
    end
    refute read
  end

  def test_inherited_key_uses_the_ancestor_expiry
    enroll_at(@org, "org")
    set_entry(@org, "scope" => "tree", "expires_at" => "2026-11-01")
    enroll_at(@project, "x", "gemini")
    set_entry(@project, { "expires_at" => "2099-01-01" }, "gemini")
    err = assert_raises(CfSecrets::Expired) { resolve_at(NOW) }
    assert_equal @org, err.owner_root
    assert_equal @project, err.root
    assert_includes err.correct, "--dir #{@org}"
  end

  def test_confirmed_ancestor_warns_on_its_own_expiry
    enroll_at(@org, "org")
    confirm("openai", @org)
    set_entry(@org, "expires_at" => "2026-11-16")
    assert_equal "org", resolve_at(NOW)
    assert_includes @err.string, "enrolled at #{@org} expires at 2026-11-16"
  end
end
