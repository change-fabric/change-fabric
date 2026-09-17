# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/change_stale_content_check"
require "tmpdir"

class ChangeStaleContentCheckTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "trunk")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    write("shared.txt", "a\nb\nc\n")
    write("untouched.txt", "x\n")
    git("add", ".")
    git("commit", "-q", "-m", "base")
    git("branch", "pr")
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def git(*args) = GitFixture.git(@repo, *args)
  def write(name, contents) = File.write(File.join(@repo, name), contents)

  def test_flags_a_trunk_fix_the_pr_never_touched
    git("checkout", "-q", "pr")
    write("untouched.txt", "pr change\n")
    git("commit", "-q", "-am", "pr change")

    git("checkout", "-q", "trunk")
    write("shared.txt", "a\nb-FIXED\nc\n")
    git("commit", "-q", "-am", "trunk fix")

    result = ChangeStaleContentCheck.missing_from("pr", "trunk", dir: @repo)
    assert_equal [ "shared.txt" ], result.missing_files
    assert_empty result.conflicted_files
  end

  # A PR that touches none of the files trunk changed since it was cut cannot
  # revert those files by merging: a squash merge only ever applies the PR's
  # own diff. require_base_changed narrows to the intersection so this class
  # of finding, which fires on nearly every PR under normal merge cadence,
  # never surfaces.
  def test_require_base_changed_drops_a_fix_in_a_file_the_pr_never_touched
    git("checkout", "-q", "pr")
    write("untouched.txt", "pr change to an unrelated file\n")
    git("commit", "-q", "-am", "pr change")

    git("checkout", "-q", "trunk")
    write("shared.txt", "a\nb-FIXED\nc\n")
    git("commit", "-q", "-am", "trunk fix")

    result = ChangeStaleContentCheck.missing_from("pr", "trunk", dir: @repo, require_base_changed: true)
    assert_empty result.missing_files
  end

  def test_require_base_changed_still_flags_a_file_both_sides_touch
    # Both sides edit lines far enough apart that git's default diff context
    # does not overlap, so the merge is clean and the finding depends only
    # on the intersection, not on a conflict.
    base_lines = (1..20).map { |n| "line#{n}" }
    git("checkout", "-q", "trunk")
    write("shared.txt", "#{base_lines.join("\n")}\n")
    git("commit", "-q", "-am", "give shared.txt twenty lines")
    git("checkout", "-q", "pr")
    git("merge", "-q", "trunk")

    git("checkout", "-q", "pr")
    pr_lines = base_lines.dup.tap { |lines| lines[1] = "line2-from-pr" }
    write("shared.txt", "#{pr_lines.join("\n")}\n")
    git("commit", "-q", "-am", "pr change near the top")

    git("checkout", "-q", "trunk")
    trunk_lines = base_lines.dup.tap { |lines| lines[18] = "line19-from-trunk" }
    write("shared.txt", "#{trunk_lines.join("\n")}\n")
    git("commit", "-q", "-am", "trunk change near the bottom")

    result = ChangeStaleContentCheck.missing_from("pr", "trunk", dir: @repo, require_base_changed: true)
    assert_equal [ "shared.txt" ], result.missing_files
  end

  def test_a_real_conflict_is_not_reported_as_missing
    git("checkout", "-q", "pr")
    write("shared.txt", "a\nb-FROM-PR\nc\n")
    git("commit", "-q", "-am", "pr also changes the same line")

    git("checkout", "-q", "trunk")
    write("shared.txt", "a\nb-FIXED\nc\n")
    git("commit", "-q", "-am", "trunk fix")

    result = ChangeStaleContentCheck.missing_from("pr", "trunk", dir: @repo)
    assert_empty result.missing_files
    assert_equal [ "shared.txt" ], result.conflicted_files
  end

  def test_no_findings_when_pr_already_has_trunks_content
    git("checkout", "-q", "trunk")
    write("shared.txt", "a\nb-FIXED\nc\n")
    git("commit", "-q", "-am", "trunk fix")

    git("checkout", "-q", "pr")
    git("merge", "-q", "trunk")

    result = ChangeStaleContentCheck.missing_from("pr", "trunk", dir: @repo)
    assert_empty result.missing_files
    assert_empty result.conflicted_files
  end

  def test_post_merge_direction_flags_a_dropped_file
    git("checkout", "-q", "pr")
    write("untouched.txt", "carried by the pr\n")
    git("commit", "-q", "-am", "pr change that a squash could drop")

    # Simulate a squash merge into trunk that omits the pr's file change.
    git("checkout", "-q", "trunk")
    write("shared.txt", "a\nb\nc-touched-by-trunk\n")
    git("commit", "-q", "-am", "unrelated trunk commit standing in for a squash")

    result = ChangeStaleContentCheck.missing_from("trunk", "pr", dir: @repo)
    assert_equal [ "untouched.txt" ], result.missing_files
  end
end
