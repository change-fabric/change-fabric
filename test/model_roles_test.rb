# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../scripts/model_roles"
require_relative "../scripts/skill_compiler"
require_relative "../install"

class ModelRolesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @user = File.join(@dir, "model_roles.yml")
    @snapshot = File.join(@dir, "model_roles.resolved.json")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def repo_roles(**over) = ModelRoles.table(host: "claude", env: {}, user_file: @user, **over)

  def user_file(worker:)
    File.write(@user, YAML.dump("hosts" => { "claude" => { "worker" => worker } }))
  end

  def test_repo_map_is_the_default_and_covers_every_role
    assert_equal({ "orchestrator" => "opus", "worker" => "sonnet", "author" => "opus", "critic" => "opus", "classifier" => "haiku" },
                 repo_roles)
  end

  def test_env_beats_user_file_beats_repo
    user_file(worker: "haiku")
    assert_equal "haiku", ModelRoles.model_for("worker", host: "claude", env: {}, user_file: @user)
    assert_equal "opus", ModelRoles.model_for("worker", host: "claude", env: { "CF_MODEL_WORKER" => "opus" }, user_file: @user)
    assert_equal "sonnet", ModelRoles.model_for("worker", host: "claude", env: {}, user_file: File.join(@dir, "none.yml"))
    assert_equal({ "worker" => "env", "critic" => "repo" },
                 ModelRoles.sources(host: "claude", env: { "CF_MODEL_WORKER" => "opus" }, user_file: @user).slice("worker", "critic"))
  end

  def test_unknown_role_raises
    error = assert_raises(ArgumentError) { ModelRoles.model_for("planner", host: "claude", env: {}, user_file: @user) }
    assert_includes error.message, "planner"
  end

  def test_host_missing_from_the_map_returns_nil_even_with_an_env_override
    env = { "CF_MODEL_WORKER" => "opus" }
    assert_nil ModelRoles.model_for("worker", host: "codex", env: env, user_file: @user)
    assert_nil ModelRoles.table(host: "codex", env: env, user_file: @user)
  end

  def test_malformed_user_file_warns_once_and_is_ignored
    File.write(@user, "hosts: [unclosed")
    _out, err = capture_io do
      2.times { assert_equal "sonnet", ModelRoles.model_for("worker", host: "claude", env: {}, user_file: @user) }
    end
    assert_equal 1, err.scan("ignoring malformed model roles file").size
  end

  def test_unsafe_model_strings_are_rejected_from_every_source
    [ "o\"pus", "o\\pus", "opus\nx", "a b", "" + "x" * 65 ].each do |bad|
      error = assert_raises(ModelRoles::InvalidModel, bad.inspect) do
        ModelRoles.model_for("worker", host: "claude", env: { "CF_MODEL_WORKER" => bad }, user_file: @user)
      end
      assert_match(/worker.*env/, error.message)

      user_file(worker: bad)
      error = assert_raises(ModelRoles::InvalidModel, bad.inspect) { ModelRoles.model_for("worker", host: "claude", env: {}, user_file: @user) }
      assert_match(/worker.*user file/, error.message)

      repo = File.join(@dir, "repo.yml")
      File.write(repo, YAML.dump("hosts" => { "claude" => { "worker" => bad } }))
      error = assert_raises(ModelRoles::InvalidModel, bad.inspect) do
        ModelRoles.model_for("worker", host: "claude", env: {}, user_file: nil, repo_file: repo)
      end
      assert_match(/worker.*repo/, error.message)
    end
  end

  def test_provider_style_model_ids_are_accepted
    %w[opus claude-sonnet-5-5 gpt-5.4 us.anthropic.claude:v1 claude-opus-5[1m]].each do |good|
      assert_equal good, ModelRoles.model_for("worker", host: "claude", env: { "CF_MODEL_WORKER" => good }, user_file: @user)
    end
  end

  def test_snapshot_round_trips_and_role_of_reads_it
    roles = repo_roles
    ModelRoles.write_snapshot(host: "claude", roles: roles, sources: { "worker" => "repo" }, path: @snapshot)
    assert_equal roles, ModelRoles.snapshot_roles("claude", path: @snapshot)
    assert_nil ModelRoles.snapshot_roles("codex", path: @snapshot)
    assert_equal %w[orchestrator author critic], ModelRoles.role_of("opus", host: "claude", roles: ModelRoles.snapshot_roles("claude", path: @snapshot))
    assert_empty Dir.glob("#{@snapshot}.tmp.*"), "the temp file is renamed away"
  end

  def test_missing_or_corrupt_snapshot_reads_as_nil
    assert_nil ModelRoles.snapshot(path: @snapshot)
    File.write(@snapshot, "{not json")
    assert_nil ModelRoles.snapshot(path: @snapshot)
    assert_nil ModelRoles.snapshot_roles("claude", path: @snapshot)
  end

  def test_drift_reports_the_role_for_an_env_override_and_for_a_user_file
    ModelRoles.write_snapshot(host: "claude", roles: repo_roles, sources: {}, path: @snapshot)
    assert_empty ModelRoles.drift(host: "claude", env: {}, user_file: @user, path: @snapshot)

    env_drift = ModelRoles.drift(host: "claude", env: { "CF_MODEL_WORKER" => "opus" }, user_file: @user, path: @snapshot)
    assert_equal({ "worker" => %w[sonnet opus] }, env_drift)

    user_file(worker: "opus")
    assert_equal({ "worker" => %w[sonnet opus] }, ModelRoles.drift(host: "claude", env: {}, user_file: @user, path: @snapshot))
    # The snapshot, which the hook and grader read, still says sonnet.
    assert_equal "sonnet", ModelRoles.snapshot_roles("claude", path: @snapshot).fetch("worker")
    assert_includes ModelRoles.drift_message(env_drift), "worker sonnet -> opus"
    assert_includes ModelRoles.drift_message(env_drift), "install.rb"
  end

  def test_no_snapshot_means_no_drift
    assert_empty ModelRoles.drift(host: "claude", env: { "CF_MODEL_WORKER" => "opus" }, user_file: @user, path: @snapshot)
  end
end

# install.rb resolves once, compiles from that map, and writes the snapshot last.
class ModelRolesInstallTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)

  def setup
    @home = Dir.mktmpdir
    @repo = Dir.mktmpdir
    %w[scripts config workflows extensions].each { |dir| File.symlink(File.join(REPO, dir), File.join(@repo, dir)) }
    FileUtils.mkdir_p(File.join(@repo, "skills"))
    FileUtils.cp_r(File.join(REPO, "skills", "merge-ready"), File.join(@repo, "skills", "merge-ready"))
    @snapshot = File.join(@home, ".local", "state", "change-fabric", "model_roles.resolved.json")
    @old_state = ENV.delete("CF_STATE_HOME")
  end

  def teardown
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
    ENV["CF_STATE_HOME"] = @old_state if @old_state
  end

  def install(env = {})
    paths = Install::Paths.new(repo: @repo, home: @home)
    saved = ENV.to_h.slice(*env.keys)
    env.each { |key, value| ENV[key] = value }
    capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
  ensure
    env.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def test_install_writes_the_resolved_snapshot_and_renders_skills_from_it
    File.write(File.join(@repo, "skills", "merge-ready", "extra.md"), "tier {{model:worker}} and {{model:critic}}\n")
    File.write(File.join(@repo, "skills", "merge-ready", "spawn.js"), "agent({ a: 1, model: {{model-js:worker}} })\n")
    install("CF_MODEL_WORKER" => "haiku")
    data = JSON.parse(File.read(@snapshot))
    assert_equal "haiku", data.dig("roles", "worker")
    assert_equal "env", data.dig("sources", "worker")
    compiled = File.join(@home, ".local/share/change-fabric/skills/claude/cf:merge-ready")
    assert_equal "tier haiku and opus\n", File.read(File.join(compiled, "extra.md"))
    assert_equal %(agent({ a: 1, model: "haiku" })\n), File.read(File.join(compiled, "spawn.js"))
    codex = File.join(@home, ".agents/skills/cf-merge-ready")
    assert_equal "tier the host's worker-tier model and the host's critic-tier model\n", File.read(File.join(codex, "extra.md"))
    assert_equal "agent({ a: 1 })\n", File.read(File.join(codex, "spawn.js"))
  end

  def test_a_failed_compile_leaves_the_old_snapshot_and_exits_nonzero
    install
    before = File.read(@snapshot)
    File.write(File.join(@repo, "skills", "merge-ready", "bad.js"), "const x = {{model-js:worker}};\n")
    assert_raises(ArgumentError) { install("CF_MODEL_WORKER" => "haiku") }
    assert_equal before, File.read(@snapshot)
  end

  def test_an_invalid_override_fails_install_before_anything_is_written
    assert_raises(ModelRoles::InvalidModel) { install("CF_MODEL_WORKER" => 'o"pus') }
    refute File.exist?(@snapshot)
  end

  def test_install_prints_drift_when_an_override_changed_since_the_last_install
    install
    out, = install("CF_MODEL_WORKER" => "opus")
    assert_includes out, "worker sonnet -> opus"
  end
end
