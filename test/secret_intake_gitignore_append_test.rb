# frozen_string_literal: true

require_relative "secret_intake_helpers"
require "open3"

class SecretIntakeGitignoreAppendTest < Minitest::Test
  include SecretIntakeHelpers

  def git_repo(dir)
    _out, err, status = Open3.capture3("git", "-C", dir, "init", "-q")
    skip "git unavailable: #{err}" unless status.success?
    dir
  end

  def push(path) = SecretIntake::Destinations::EnvFile.new(path: path).push("API_TOKEN", SENTINEL)

  def test_an_unignored_env_file_is_appended_and_reported
    Dir.mktmpdir do |dir|
      repo = git_repo(File.realpath(dir))
      FileUtils.mkdir_p(File.join(repo, "app"))
      File.write(File.join(repo, ".gitignore"), "node_modules")
      lines = push(File.join(repo, "app", ".env.local"))
      assert_equal "node_modules\n/app/.env.local\n", File.read(File.join(repo, ".gitignore"))
      assert_match %r{appended /app/\.env\.local to}, lines.last
      _out, _err, status = Open3.capture3("git", "-C", repo, "check-ignore", "-q", "app/.env.local")
      assert status.success?
    end
  end

  def test_an_already_ignored_file_leaves_gitignore_alone
    Dir.mktmpdir do |dir|
      repo = git_repo(File.realpath(dir))
      File.write(File.join(repo, ".gitignore"), ".env*\n")
      lines = push(File.join(repo, ".env.local"))
      assert_equal ".env*\n", File.read(File.join(repo, ".gitignore"))
      assert_equal 1, lines.size
    end
  end

  def test_outside_a_repo_is_a_no_op
    Dir.mktmpdir do |dir|
      lines = push(File.join(dir, ".env"))
      refute File.exist?(File.join(dir, ".gitignore"))
      assert_equal 1, lines.size
    end
  end
end
