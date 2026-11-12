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
  end
end
