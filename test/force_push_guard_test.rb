# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../scripts/force_push_guard"

class ForcePushGuardTest < Minitest::Test
  ESCAPES = %w[CF_ALLOW_UNGATED_MERGE CF_ALLOW_HOSTDAEMON CF_ALLOW_SENSITIVE_TERM].freeze

  def decision(command, branch: "feature/x", protected_branches: %w[staging])
    io = StringIO.new
    ForcePushGuard.new({ "tool_name" => "Bash", "tool_input" => { "command" => command } }, branch: branch,
                                                                                         protected_branches: protected_branches).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  DENIED = [
    "git push -f origin main",
    "git push origin +main",
    "git push --force-with-lease origin HEAD:main",
    "git push origin :main",
    "git push --delete origin main",
    "gh api -X DELETE repos/o/r/git/refs/heads/main",
    "git push --force origin main",
    "git push -fu origin master",
    "git push --force-with-lease=main:abc origin main",
    "git push --force origin staging",
    "git push --mirror origin",
    "git push origin refs/heads/main --force-if-includes --force-with-lease",
    "cd x && git push -f origin main",
    "gh api --method DELETE repos/o/r/branches/main/protection",
    "gh api -X PATCH repos/o/r/git/refs/heads/main -F force=true -f sha=abc",
    "git filter-repo --path secret --invert-paths && git push origin main",
    "git push --force --all origin",
    "git push -f --branches origin",
    "git push --force origin 'refs/heads/*:refs/heads/*'",
    "git push -f origin +refs/heads/*",
    "git push origin ':refs/heads/*'",
    "git push -f origin main; git status",
    "git push -f origin main;git status",
    "git push -f origin main&&echo ok",
    "git push -f origin main||true",
    "git push -f origin main|cat",
    "git push -f origin main &",
    "git status\ngit push -f origin main",
    "true;git push -f origin main"
  ].freeze

  def test_trunk_rewrites_and_deletes_are_denied_with_every_escape_set
    DENIED.each { |cmd| assert_equal "deny", decision(cmd), cmd }
    saved = ESCAPES.to_h { |name| [ name, ENV.fetch(name, nil) ] }
    ESCAPES.each { |name| ENV[name] = "1" }
    DENIED.each { |cmd| assert_equal "deny", decision(cmd), "#{cmd} with escapes set" }
  ensure
    saved&.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  # An open autopilot changes nothing here: the guard never consults one.
  def test_the_guard_never_consults_an_autopilot_or_an_env_var
    source = File.read(File.expand_path("../scripts/force_push_guard.rb", __dir__)).lines.reject { |line| line.strip.start_with?("#") }.join
    refute_match(/ChangeAutopilot|change_autopilot|ENV\[/, source)
  end

  def test_a_bare_force_push_on_trunk_or_an_unknown_branch_is_denied
    assert_equal "deny", decision("git push -f", branch: "main")
    assert_equal "deny", decision("git push --force origin HEAD", branch: "main")
    assert_nil decision("git push -f", branch: "feature/x")
  end

  def test_feature_branch_force_and_ordinary_pushes_are_allowed
    [ "git push --force-with-lease origin feature/x",
      "git push -f origin HEAD",
      "git push origin main",
      "git push -u origin feature/x",
      "git push --delete origin feature/x",
      "gh api -X DELETE repos/o/r/git/refs/heads/feature/x",
      "gh api repos/o/r/git/refs/heads/main",
      "git rebase -i main",
      "git commit -m 'never git push -f origin main'" ].each { |cmd| assert_nil decision(cmd), cmd }
  end

  def test_an_unparseable_forced_push_fails_closed
    assert_equal "deny", decision("git push -f origin main 'unterminated")
    assert_nil decision("echo 'unterminated")
  end

  def test_non_bash_tools_are_ignored
    io = StringIO.new
    ForcePushGuard.new({ "tool_name" => "Write", "tool_input" => { "content" => "git push -f origin main" } }, branch: "x", protected_branches: []).emit(io)
    assert_empty io.string
  end

  def test_guarded_command_helpers
    assert GuardedCommand.force_push?("git push -f origin x")
    assert GuardedCommand.force_push?("git push origin +x")
    refute GuardedCommand.force_push?("git push origin x")
    assert GuardedCommand.delete_push?("git push origin :x")
    assert GuardedCommand.delete_push?("git push --delete origin x")
    refute GuardedCommand.delete_push?("git push origin x")
  end

  def test_shell_aware_tokens_split_glued_operators_and_keep_quotes
    assert_equal [ "git", "push", "origin", "main", ";", "git", "status" ], GuardedCommand.tokens("git push origin main;git status")
    assert_equal [ "a", "&&", "b", "||", "c", "|", "d", ";", "e" ], GuardedCommand.tokens("a&&b||c|d\ne")
    assert_equal [ "git", "commit", "-m", "x; git push -f origin main" ], GuardedCommand.tokens("git commit -m 'x; git push -f origin main'")
    assert_equal [ "echo", "a \"b\" c" ], GuardedCommand.tokens('echo "a \\"b\\" c"')
    assert_equal [ "cmd", "2>&1", "|", "tee", "log" ], GuardedCommand.tokens("cmd 2>&1 | tee log")
    assert_equal [ "a b" ], GuardedCommand.tokens("a\\ b")
  end

  def test_other_guards_still_parse_their_cases
    assert GuardedCommand.push?("cd x && git push -u origin feat/x")
    assert GuardedCommand.merge?("gh pr merge 1 --squash;echo done")
    refute GuardedCommand.merge?("gh pr edit --body 'run gh pr merge later'")
    assert GuardedCommand.pr_create?("gh pr create --title t --body 'a; b'")
    assert GuardedCommand.tag_push?("git push origin skills/v1.2.3")
    refute GuardedCommand.tag_push?("git push")
    assert_equal "a direct push to the trunk", GuardedCommand.new("git push origin main;echo", "merge-ready").violation
    assert_nil GuardedCommand.new("git push origin feat/x", "merge-ready").violation
  end

  def test_dash_c_resolves_the_branch_in_the_target_repo
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i", out: File::NULL)
      io = StringIO.new
      ForcePushGuard.new({ "tool_name" => "Bash", "tool_input" => { "command" => "git -C #{dir} push --force-with-lease" } }, protected_branches: []).emit(io)
      assert_includes io.string, "force-push to 'main'"
    end
  end

  def test_each_push_resolves_its_own_repository
    Dir.mktmpdir do |dir|
      feature = File.join(dir, "feature")
      system("git", "init", "-q", "-b", "feat/x", feature, out: File::NULL, err: File::NULL)
      system("git", "-C", feature, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i", out: File::NULL)
      io = StringIO.new
      command = "git push --force-with-lease; git -C #{feature} push"
      guard = ForcePushGuard.new({ "tool_name" => "Bash", "tool_input" => { "command" => command } }, branch: "main", protected_branches: [])
      guard.emit(io)
      assert_includes io.string, "force-push to 'main'"
    end
  end
end
