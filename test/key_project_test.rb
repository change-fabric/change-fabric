# frozen_string_literal: true

require "minitest/autorun"
require_relative "key_project_helpers"
require_relative "../scripts/key_project"

class KeyProjectTest < Minitest::Test
  include KeyProjectHelpers

  def setup
    @scratch = make_scratchpad!
    @repo = make_repo!(File.join(@kp_tmp, "app"))
  end

  def teardown = remove_scratchpad!

  def uid = Process.uid

  def test_matcher_table
    {
      "/private/tmp/claude-#{uid}/-Users-me-app/abc/scratchpad" => true,
      "/private/tmp/claude-#{uid}/-Users-me-app/abc/scratchpad/sub/dir" => true,
      "/tmp/claude-#{uid}/-Users-me-app/abc/scratchpad" => true,
      "/tmp/claude-#{uid}/-Users-me-app/abc/scratchpad/x" => true,
      "/private/tmp/claude-#{uid + 1}/-Users-me-app/abc/scratchpad" => false,
      "/private/tmp/claude-#{uid}/-Users-me-app/abc" => false,
      "/private/tmp/claude-#{uid}/-Users-me-app/abc/scratchpad-extra" => false,
      "/private/tmp/claude-#{uid}/a/b/c/scratchpad" => false,
      "/private/tmp/other-#{uid}/-Users-me-app/abc/scratchpad" => false,
      "/Users/me/code/app" => false,
      "/Users/me/claude-#{uid}/x/y/scratchpad" => false
    }.each do |path, expected|
      assert_equal expected, KeyProject.scratch_root?(path), path
    end
  end

  def test_matcher_covers_the_tmpdir_root_and_rejects_a_nil_path
    assert KeyProject.scratch_root?(@scratch)
    assert KeyProject.scratch_root?(File.join(@scratch, "deep"))
    refute KeyProject.scratch_root?(nil)
    refute KeyProject.scratch_root?(@kp_tmp)
  end

  def test_explicit_project_returns_its_realpath_and_prints_nothing
    link = File.join(@kp_tmp, "link")
    File.symlink(@repo, link)
    assert_output("", "") { assert_equal @repo, KeyProject.resolve(argv_project: link) }
  end

  def test_explicit_project_must_be_an_existing_directory
    err = assert_raises(KeyProject::Invalid) { KeyProject.resolve(argv_project: File.join(@kp_tmp, "nope")) }
    assert_includes err.message, "--project"
    assert_includes err.message, "not a directory"
    File.write(File.join(@kp_tmp, "file"), "x")
    assert_raises(KeyProject::Invalid) { KeyProject.resolve(argv_project: File.join(@kp_tmp, "file")) }
  end

  def test_explicit_project_naming_a_scratchpad_is_refused_without_reading_a_record
    env = Class.new { def [](_) = raise("the session env was read") }.new
    err = assert_raises(KeyProject::Invalid) { KeyProject.resolve(argv_project: @scratch, env: env) }
    assert_includes err.message, @scratch
    assert_includes err.message, "scratchpad"
    assert_includes err.message, "Pass the repo root instead."
  end

  def test_invalid_is_an_option_error_so_clis_exit_2
    assert_kind_of OptionParser::ParseError, KeyProject::Invalid.new("x")
  end

  def test_cwd_outside_a_scratchpad_is_returned_unchanged_and_silent
    assert_output("", "") { assert_equal @repo, KeyProject.resolve(cwd: @repo, env: {}) }
  end

  def test_scratchpad_cwd_without_a_project_is_unresolved_with_the_fix
    err = assert_raises(KeyProject::Unresolved) do
      KeyProject.resolve(cwd: @scratch, env: { "CLAUDE_CODE_SESSION_ID" => "sid-9" })
    end
    assert_kind_of WalkthroughEnv::NeedsEnrollment, err
    assert_includes err.message, @scratch
    assert_includes err.message, "session record for sid-9"
    assert_includes err.message, "--project <repo root>"
    assert_equal({ reason: "scratchpad", project_root: @scratch }, err.to_h)
  end

  def test_unresolved_names_an_unknown_session
    err = assert_raises(KeyProject::Unresolved) { KeyProject.resolve(cwd: @scratch, env: {}) }
    assert_includes err.message, "session record for unknown session"
  end

  def test_a_deleted_cwd_is_not_a_scratchpad_and_is_returned_unchanged
    gone = File.join(@kp_tmp, "gone")
    assert_equal gone, KeyProject.resolve(cwd: gone, env: {})
  end

  def test_take_option_removes_both_spellings
    argv = %w[a --project /x b]
    assert_equal "/x", KeyProject.take_option(argv)
    assert_equal %w[a b], argv
    argv = %w[--project=/y c]
    assert_equal "/y", KeyProject.take_option(argv)
    assert_equal %w[c], argv
    assert_nil KeyProject.take_option(%w[c])
    assert_raises(KeyProject::Invalid) { KeyProject.take_option(%w[--project]) }
  end
end
