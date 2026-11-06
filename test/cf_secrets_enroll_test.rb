# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "yaml"
require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/cf_secrets_enroll"

# The enrollment CLI against a tmpdir HOME. Never a real secrets path.
class CfSecretsEnrollTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("cf-enroll")
    @file = File.join(@home, "example.env")
    File.write(@file, "OPENAI_API_KEY=sk-sentinel\n")
  end

  def teardown = FileUtils.rm_rf(@home)

  def run_cli(*argv)
    @out = StringIO.new
    @err = StringIO.new
    CfSecretsEnroll.new(argv, out: @out, err: @err, home: @home).run
  end

  def store = YAML.safe_load_file(CfSecrets.store_path(@home))

  def test_set_records_and_preserves_projects
    assert_equal 0, run_cli("set", "--project-key", "a", "--source", @file, "--env-var", "OPENAI_API_KEY")
    assert_equal 0, run_cli("set", "--project-key", "b", "--source", "env")
    assert_equal 0, run_cli("set", "--project-key", "a", "--source", @file, "--provider", "openai")
    assert_equal({ "env_file" => @file, "providers" => { "openai" => @file } }, store["projects"]["a"])
    assert_equal "env", store["projects"]["b"]["env_file"]
  end

  def test_concurrent_sets_keep_every_project
    pids = 8.times.map do |i|
      fork { exit run_cli("set", "--project-key", "p#{i}", "--source", "env") }
    end
    pids.each { |pid| Process.wait(pid) }
    assert_equal 8.times.map { |i| "p#{i}" }.sort, store["projects"].keys.sort
  end

  def test_writes_0600
    run_cli("default", "--source", @file)
    assert_equal 0o600, File.stat(CfSecrets.store_path(@home)).mode & 0o777
    assert_equal @file, store["default"]
  end

  def test_rejects_missing_file
    assert_equal 2, run_cli("set", "--project-key", "a", "--source", File.join(@home, "nope.env"))
    refute File.exist?(CfSecrets.store_path(@home))
  end

  def test_rejects_missing_variable
    assert_equal 2, run_cli("set", "--project-key", "a", "--source", @file, "--env-var", "GEMINI_API_KEY")
  end

  def test_refuses_malformed_store
    path = CfSecrets.store_path(@home)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "a: [unclosed")
    assert_equal 2, run_cli("default", "--source", @file)
    assert_equal "a: [unclosed", File.read(path)
  end

  def test_warns_on_unignored_file_in_git_repo
    system("git", "-C", @home, "init", "-q", exception: true)
    run_cli("default", "--source", @file)
    assert_match(/not gitignored/, @err.string)
  end

  def test_status_never_prints_values
    run_cli("set", "--project-key", "a", "--source", @file)
    assert_equal 0, run_cli("status")
    assert_includes @out.string, "a: #{@file}"
    refute_includes @out.string, "sk-sentinel"
  end

  def test_status_empty_store
    assert_equal 0, run_cli("status")
    assert_equal "default: (none)\n", @out.string
  end
end
