# frozen_string_literal: true

require "tmpdir"
require "json"
require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/cf_secrets"

# Resolver precedence, enrollment signal, and project keying. Every path is a
# tmpdir; no real secrets file is touched.
class CfSecretsTest < Minitest::Test
  SENTINEL = "sk-sentinel-never-print"
  VARS = [ "OPENAI_API_KEY" ].freeze

  def setup
    @dir = Dir.mktmpdir("cf-secrets")
    @cwd = File.join(@dir, "proj")
    Dir.mkdir(@cwd)
    @key = CfSecrets.project_key(@cwd)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def env_file(name, value)
    path = File.join(@dir, name)
    File.write(path, "# comment\nexport OPENAI_API_KEY=\"#{value}\"\n")
    path
  end

  def resolve(env: {}, store: {}) = CfSecrets.resolve(provider: "openai", env_vars: VARS, cwd: @cwd, env:, store:)

  def project_store(entry) = { "projects" => { @key => entry } }

  def test_process_env_wins
    store = project_store("env_file" => env_file("a.env", "file"))
    env = { "OPENAI_API_KEY" => "proc", "CF_SECRETS_ENV" => env_file("p.env", "pinned") }
    assert_equal [ "proc", :process ], resolve(env:, store:)
  end

  def test_cf_secrets_env_beats_project
    store = project_store("env_file" => env_file("a.env", "file"))
    env = { "CF_SECRETS_ENV" => env_file("p.env", "pinned") }
    assert_equal [ "pinned", :cf_secrets_env ], resolve(env:, store:)
  end

  def test_provider_override_beats_env_file
    store = project_store("env_file" => env_file("a.env", "file"),
                          "providers" => { "openai" => env_file("o.env", "override") })
    assert_equal [ "override", :project ], resolve(store:)
  end

  def test_env_file_used
    assert_equal [ "file", :project ], resolve(store: project_store("env_file" => env_file("a.env", "file")))
  end

  def test_env_source_without_key_is_missing_key
    assert_raises(CfSecrets::MissingKey) { resolve(store: project_store("env_file" => "env")) }
  end

  def test_no_entry_needs_enrollment_with_default_first
    store = { "default" => "/x/default.env", "projects" => { "other" => { "env_file" => "/x/other.env" } } }
    err = assert_raises(CfSecrets::NeedsEnrollment) { resolve(store:) }
    assert_equal [ "/x/default.env", "/x/other.env", "env" ], err.candidates
    assert_equal @key, err.project_key
    assert_equal "OPENAI_API_KEY", err.env_var
  end

  def test_project_key_falls_back_to_dashed
    assert_equal CtxPaths.dashed(@cwd), @key
  end

  def test_project_key_uses_repo_id
    system("git", "-C", @cwd, "init", "-q", exception: true)
    system("git", "-C", @cwd, "remote", "add", "origin", "git@github.com:example/proj.git", exception: true)
    assert_equal "github.com/example/proj", CfSecrets.project_key(@cwd)
  end

  def test_enrollment_line_has_no_value
    store = { "default" => env_file("d.env", SENTINEL) }
    err = assert_raises(CfSecrets::NeedsEnrollment) { resolve(store:) }
    line = CfSecrets.enrollment_line(err)
    refute_includes line, SENTINEL
    assert_equal "openai", JSON.parse(line).dig("cf_enroll", "provider")
  end

  def test_load_malformed_yaml_is_empty
    path = File.join(@dir, "secrets.yml")
    File.write(path, "a: [unclosed")
    assert_empty CfSecrets.load(path)
  end
end
