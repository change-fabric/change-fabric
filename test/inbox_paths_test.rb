# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/inbox_paths"

class InboxPathsTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @cwd = File.join(@home, "project")
    FileUtils.mkdir_p(@cwd)
    @prev_env = ENV["INBOX_ROOT"]
    ENV.delete("INBOX_ROOT")
  end

  def teardown
    if @prev_env
      ENV["INBOX_ROOT"] = @prev_env
    else
      ENV.delete("INBOX_ROOT")
    end
    FileUtils.remove_entry(@home)
  end

  def write_change_md(body)
    File.write(File.join(@cwd, "CHANGE.md"), body)
  end

  def test_env_beats_change_md
    ENV["INBOX_ROOT"] = "/tmp/env-root"
    write_change_md("---\ninbox_root: ~/x\n---\n")
    assert_equal "/tmp/env-root", InboxPaths.root(cwd: @cwd, home: @home)
    assert_equal "env", InboxPaths.root_source(cwd: @cwd, home: @home)
  end

  def test_change_md_beats_default_and_expands_tilde
    write_change_md("---\ninbox_root: ~/x\n---\n")
    assert_equal File.join(@home, "x"), InboxPaths.root(cwd: @cwd, home: @home)
    assert_equal "change_md", InboxPaths.root_source(cwd: @cwd, home: @home)
  end

  def test_no_change_md_yields_default
    expected = File.join(@home, ".claude", "cf", "inbox", InboxPaths.dashed(@cwd))
    assert_equal expected, InboxPaths.root(cwd: @cwd, home: @home)
    assert_equal "default", InboxPaths.root_source(cwd: @cwd, home: @home)
  end

  def test_change_md_resolved_from_nested_cwd
    write_change_md("---\ninbox_root: ~/x\n---\n")
    nested = File.join(@cwd, "packages", "sub")
    FileUtils.mkdir_p(nested)
    assert_equal File.join(@home, "x"), InboxPaths.root(cwd: nested, home: @home)
    assert_equal "change_md", InboxPaths.root_source(cwd: nested, home: @home)
  end

  def test_change_md_relative_inbox_root_resolves_against_repo_root_not_nested_cwd
    write_change_md("---\ninbox_root: .inbox\n---\n")
    nested = File.join(@cwd, "packages", "sub")
    FileUtils.mkdir_p(nested)
    assert_equal File.join(@cwd, ".inbox"), InboxPaths.root(cwd: nested, home: @home)
  end

  def test_change_md_with_no_inbox_root_key_yields_default
    write_change_md("---\nspec_version: 0.11.0\n---\n")
    assert_equal "default", InboxPaths.root_source(cwd: @cwd, home: @home)
  end

  def test_malformed_change_md_yields_default_without_raising
    write_change_md("---\ninbox_root: [unterminated\n---\n")
    assert_equal "default", InboxPaths.root_source(cwd: @cwd, home: @home)
    expected = File.join(@home, ".claude", "cf", "inbox", InboxPaths.dashed(@cwd))
    assert_equal expected, InboxPaths.root(cwd: @cwd, home: @home)
  end

  def test_assert_project_raises_outside_pinned_home
    outside = Dir.mktmpdir
    assert_raises(InboxPaths::NotAProject) { InboxPaths.assert_project!(outside, home: @home) }
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  # Swaps InboxPaths.expected_home for a pinned home that differs from the
  # running Dir.home, without minitest/mock (absent from this bundle). The
  # redefine is wrapped to keep the warning-enabled test run quiet.
  def with_pinned_home(home)
    original = InboxPaths.method(:expected_home)
    swap_expected_home { home }
    yield
  ensure
    swap_expected_home(&original)
  end

  def swap_expected_home(&body)
    verbose = $VERBOSE
    $VERBOSE = nil
    InboxPaths.singleton_class.send(:define_method, :expected_home, &body)
  ensure
    $VERBOSE = verbose
  end

  def test_default_root_uses_pinned_home_when_runtime_home_diverges
    with_pinned_home(@home) do
      expected = File.join(@home, ".claude", "cf", "inbox", InboxPaths.dashed(@cwd))
      assert_equal expected, InboxPaths.root(cwd: @cwd)
      assert_equal "default", InboxPaths.root_source(cwd: @cwd)
    end
  end

  def test_project_check_uses_pinned_home_when_runtime_home_diverges
    with_pinned_home(@home) do
      assert InboxPaths.project_cwd?(@cwd)
      assert_raises(InboxPaths::NotAProject) { InboxPaths.root(cwd: File.join(Dir.home, "elsewhere")) }
    end
  end

  def test_default_root_not_minted_outside_pinned_home
    outside = Dir.mktmpdir
    assert_raises(InboxPaths::NotAProject) { InboxPaths.default_root(outside, home: @home) }
  ensure
    FileUtils.remove_entry(outside) if outside
  end
end
