#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "test_helpers"

# Behavioral coverage for the canonical fail-closed CI diff-grep idiom
# documented in skills/README.md, "CI diff-grep checks". Extracts the actual
# fenced block between fixed markers (not a hand-copied rewrite of it) so a
# future edit to the canonical form is exercised by these fixtures rather than
# silently drifting out of sync with them.
#
# The lint half (no site still uses the old xargs-into-git-grep form) lands in
# the next phase's commit, alongside the 12 rewritten sites.
class SkillCiIdiomTest < Minitest::Test
  README_PATH = File.expand_path("../skills/README.md", __dir__)
  START_MARKER = "<!-- CI-DIFF-GREP-IDIOM-START -->"
  END_MARKER = "<!-- CI-DIFF-GREP-IDIOM-END -->"

  PATHSPEC = "'*.txt'"
  PATTERN = "NEEDLE"

  def setup
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def git(*args) = GitFixture.git(@repo, *args)

  def write(name, contents)
    path = File.join(@repo, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
  end

  def base_sha
    GitFixture.run("-C", @repo, "rev-parse", "HEAD", label: "rev-parse HEAD").strip
  end

  def idiom
    @idiom ||= begin
      readme = File.read(README_PATH)
      start_at = readme.index(START_MARKER)
      end_at = readme.index(END_MARKER)
      raise "CI diff-grep idiom markers not found in #{README_PATH}" unless start_at && end_at

      block = readme[start_at...end_at]
      fence = block[/```bash\n(.*?)\n```/m, 1]
      raise "no bash fence found between CI diff-grep idiom markers" unless fence

      fence
    end
  end

  def script(pathspecs: PATHSPEC, pattern: PATTERN)
    idiom.sub("__PATHSPECS__", pathspecs).sub("__PAT__", pattern)
  end

  # Runs the idiom with BASE_REF in the environment (or unset) inside the
  # fixture repo's working tree. Returns [success_boolean, combined_output].
  def run_idiom(base_ref:, pathspecs: PATHSPEC, pattern: PATTERN)
    env = GitFixture::CLEAN_ENV.dup
    env["BASE_REF"] = base_ref if base_ref
    out, status = Open3.capture2e(env, "bash", "-c", script(pathspecs: pathspecs, pattern: pattern),
                                   chdir: @repo)
    [ status.success?, out ]
  end

  def test_unresolvable_base_ref_fails_closed
    write("a.txt", "one\n")
    commit("initial")

    ok, = run_idiom(base_ref: "does-not-exist")
    refute ok, "an unresolvable BASE_REF must fail the check, not pass it"
  end

  def test_invalid_pcre_pattern_fails_closed
    write("a.txt", "one\n")
    commit("initial")
    base = base_sha
    write("a.txt", "two\n")
    commit("change")

    ok, = run_idiom(base_ref: base, pattern: "(unclosed")
    refute ok, "a git grep error (bad pattern) must fail the check, not pass it"
  end

  def test_rename_plus_edit_introducing_pattern_fails
    write("old.txt", "one\n")
    commit("initial")
    base = base_sha
    git("mv", "old.txt", "new.txt")
    write("new.txt", "one\nNEEDLE\n")
    commit("rename and edit")

    ok, = run_idiom(base_ref: base)
    refute ok, "--no-renames must still catch a pattern introduced under a renamed file's new name"
  end

  def test_empty_changed_file_list_passes
    write("a.txt", "one\n")
    commit("initial")
    base = base_sha
    write("a.rb", "NEEDLE\n")
    commit("unrelated change outside the pathspec")

    ok, = run_idiom(base_ref: base)
    assert ok, "no files in the pathspec's scope changed, so the check must pass"
  end

  def test_filename_with_spaces_containing_pattern_fails
    write("a.txt", "one\n")
    commit("initial")
    base = base_sha
    write("has spaces.txt", "NEEDLE\n")
    commit("add file with spaces in its name")

    ok, = run_idiom(base_ref: base)
    refute ok, "a match inside a filename containing spaces must still be caught"
  end

  def test_clean_change_passes
    write("a.txt", "one\n")
    commit("initial")
    base = base_sha
    write("a.txt", "one\ntwo\n")
    commit("clean change")

    ok, = run_idiom(base_ref: base)
    assert ok, "a changed file with no match for the pattern must pass"
  end

  def test_match_in_changed_file_fails
    write("a.txt", "one\n")
    commit("initial")
    base = base_sha
    write("a.txt", "one\nNEEDLE\n")
    commit("introduce the forbidden pattern")

    ok, = run_idiom(base_ref: base)
    refute ok, "a changed file containing the forbidden pattern must fail the check"
  end
end

# Static lint: no skills/*/SKILL.md may still use the old fail-open idiom,
# which piped git diff into xargs -I{} git grep (fail-open on an empty diff)
# or paired git diff with [ -z "$out" ] (same fail-open shape by its exit
# check). Scans only skills/*/SKILL.md so README prose describing the old
# form by name never trips it.
class SkillCiIdiomLintTest < Minitest::Test
  SKILLS_DIR = File.expand_path("../skills", __dir__)

  def offending_lines
    Dir.glob(File.join(SKILLS_DIR, "*", "SKILL.md")).sort.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, idx|
        "#{path}:#{idx + 1}" if yield(line)
      end
    end
  end

  def test_no_site_pipes_xargs_into_git_grep
    offenders = offending_lines { |line| line.include?("xargs -I{} git grep") }
    assert_empty offenders, "fail-open xargs-into-git-grep idiom still present"
  end

  def test_no_site_uses_old_git_diff_dash_z_empty_check
    offenders = offending_lines { |line| line.include?("git diff") && line.include?('[ -z "$out" ]') }
    assert_empty offenders, "fail-open git diff / [ -z \"$out\" ] idiom still present"
  end

  # A git grep whose output is redirected to a file and read back later must
  # have its status checked right away: an I/O or repo error (exit 2+) leaves
  # the file empty, which the later read would treat as a pass.
  def test_every_redirected_git_grep_checks_its_status
    offenders = offending_lines { |line| line.match?(/git grep [^;]*>"\$\w+"; (?!s=\$\?)/) }
    assert_empty offenders, "a redirected git grep ignores its exit status"
  end
end
