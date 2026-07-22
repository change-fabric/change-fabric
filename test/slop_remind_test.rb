# frozen_string_literal: true

require_relative "test_helpers"

class SlopRemindTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    skill_dir("pst:ai-slop", auto: { "all_files" => true }, body: "SLOP-RUBRIC")
  end

  def teardown
    FileUtils.remove_entry(@skills)
    super
  end

  def remind(command, session: "s1", tool: "Bash")
    io = StringIO.new
    event = { "session_id" => session, "tool_name" => tool, "tool_input" => { "command" => command } }
    SlopRemind.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_reminds_on_git_commit_with_full_rubric_first_time
    text = remind("git commit -m 'x'")
    assert_includes text, "commit message"
    assert_includes text, "SLOP-RUBRIC"
  end

  def test_reminds_on_branch_creation
    assert_includes remind("git checkout -b feat/x"), "branch name"
    assert_includes remind("git switch -c feat/y", session: "s2"), "branch name"
  end

  def test_reminds_on_pr_authoring
    assert_includes remind("gh pr create --fill"), "PR title or description"
    assert_includes remind("gh pr edit 5 --body x", session: "s3"), "PR title or description"
  end

  def test_body_injected_once_then_pointer
    assert_includes remind("git commit -m a"), "SLOP-RUBRIC"
    second = remind("gh pr create")
    assert_includes second, "PR title or description"
    refute_includes second, "SLOP-RUBRIC", "body already in context; pointer only"
  end

  def test_each_category_reminds_once
    assert remind("git commit -m a")
    assert_nil remind("git commit -m b"), "commit category already reminded"
  end

  def test_ignores_unrelated_commands
    assert_nil remind("git status")
    assert_nil remind("ls -la")
    assert_nil remind("git log --oneline")
    assert_nil remind("git branch -a")
  end

  def test_ignores_non_bash_tools
    assert_nil remind("git commit", tool: "Edit")
  end

  def test_ignores_git_log_mentioning_commit_in_grep
    assert_nil remind('git log --grep "commit message cleanup"')
  end

  def test_ignores_pr_view_mentioning_create_in_query
    assert_nil remind('gh pr view 12 --json title -q "note: run gh pr create later"')
  end

  def test_silent_without_ai_slop_skill
    empty = Dir.mktmpdir
    io = StringIO.new
    event = { "session_id" => "s9", "tool_name" => "Bash", "tool_input" => { "command" => "git commit" } }
    SlopRemind.new(event, skills: SkillRegistry.load(empty)).emit(io)
    assert_empty io.string
  ensure
    FileUtils.remove_entry(empty)
  end
end
