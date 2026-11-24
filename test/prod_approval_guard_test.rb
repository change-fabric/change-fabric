# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/prod_approval_guard"

class ProdApprovalGuardTest < Minitest::Test
  def decide(command, tool: "Bash", cwd: Dir.pwd)
    io = StringIO.new
    ProdApprovalGuard.new({ "tool_name" => tool, "cwd" => cwd, "tool_input" => { "command" => command } }).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def assert_denied(command) = assert_equal("deny", decide(command), command)

  def assert_allowed(command, **opts) = assert_nil(decide(command, **opts), command)

  def test_denies_the_human_only_approval_tool_however_it_is_wrapped
    assert_denied "ruby ~/.claude/cf/bin/change_prod_approve.rb 1234 --remote"
    assert_denied "cd repo && ruby scripts/change_prod_approve.rb abc"
    assert_denied "bash -c 'ruby /x/change_prod_approve.rb abc'"
    assert_denied "echo 1 | ruby change_prod_approve.rb abc"
  end

  def test_queued_scripts_run_only_through_the_approved_runner
    runner = "ruby ~/code/change-fabric/change-fabric/scripts/cf_run_approved.rb"
    assert_allowed "#{runner} ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_allowed "ls ~/.claude/cf/manual/queue"
    assert_allowed "cat ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "bash ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "sh -c 'bash ~/.claude/cf/manual/queue/0016-redeploy.sh'"
    assert_denied "source ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "cd ~/.claude/cf/manual/queue && ./0016-redeploy.sh"
    assert_denied "ruby ~/.claude/cf/manual/queue/0016-x.rb"
    assert_denied "bash -e ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "bash -o pipefail -x ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "env FOO=1 bash -eu ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "FOO=1 nohup sh ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "cd ~/.claude/cf/manual/queue;./0016-redeploy.sh"
    assert_allowed "grep bash ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "bash < ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "bash 2>/dev/null ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "bash -e 2>&1 >/dev/null ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "sh -e <~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_denied "cat ~/.claude/cf/manual/queue/0016-redeploy.sh | bash"
    assert_denied "cat ~/.claude/cf/manual/queue/0016-redeploy.sh | sudo sh -s"
    assert_allowed "cat ~/.claude/cf/manual/queue/0016-redeploy.sh | head -5"
    assert_allowed "ruby scripts/approval_console.rb request --type run-script --script ~/.claude/cf/manual/queue/0016-redeploy.sh --title redeploy"
    assert_denied "bash -c -e ~/.claude/cf/manual/queue/0016-redeploy.sh"
    assert_allowed "ls -la ~/.claude/cf/manual/queue | head"
    assert_denied "#{runner} ~/.claude/cf/manual/queue/0016-redeploy.sh; bash ~/.claude/cf/manual/queue/0017-x.sh"
  end

  def test_a_shell_already_in_the_queue_dir_cannot_run_scripts_by_relative_path
    queue = File.join(Dir.home, ".claude/cf/manual/queue")
    assert_denied_in "./0016-redeploy.sh", queue
    assert_denied_in "bash -e 0016-redeploy.sh", queue
    assert_denied_in "bash custom-name.sh", queue
    assert_allowed "./0016-redeploy.sh", cwd: Dir.pwd
    assert_allowed "ls", cwd: queue
    assert_allowed "ruby ~/code/change-fabric/change-fabric/scripts/cf_run_approved.rb 0016-redeploy.sh", cwd: queue
  end

  def assert_denied_in(command, cwd) = assert_equal("deny", decide(command, cwd: cwd), "#{command} in #{cwd}")

  def test_denies_approving_a_pending_deployment
    assert_denied "gh api repos/o/r/actions/runs/123/pending_deployments -X POST -f state=approved"
    assert_denied "gh api repos/o/r/actions/runs/123/pending_deployments"
    assert_denied "gh api --method POST repos/o/r/actions/runs/9/pending_deployments --input body.json"
  end

  def test_denies_environment_writes_but_not_reads
    assert_denied "gh api -X PUT repos/o/r/environments/production -f wait_timer=0"
    assert_denied "gh api repos/o/r/environments/production -f deployment_branch_policy=null"
    assert_denied "gh api --method=DELETE repos/o/r/environments/production"
    assert_denied "gh api -XPATCH repos/o/r/environments/production/deployment-branch-policies/1"
    assert_denied "gh api repos/o/r/environments/production/deployment-branch-policies --input p.json"
    assert_allowed "gh api repos/o/r/environments"
    assert_allowed "gh api repos/o/r/environments/production"
    assert_allowed "gh api -X GET repos/o/r/environments/production"
    assert_allowed "gh api --method GET repos/o/r/environments/production -f per_page=1"
  end

  def test_denies_raw_writes_to_the_autopilot_and_audit_refs
    id = "a" * 64
    assert_denied "git push origin refs/cf-prod/autopilots/#{id}:refs/cf-prod/autopilots/#{id}"
    assert_denied "git push origin :refs/cf-prod/autopilot-ends/#{id}"
    assert_denied "git update-ref -d refs/cf-prod/autopilot-ends/#{id}"
    assert_denied "git update-ref refs/cf-prod/audit/1234 HEAD"
    assert_denied "gh api -X DELETE repos/o/r/git/refs/cf-prod/autopilot-ends/#{id}"
  end

  def test_the_autopilot_end_and_prod_dispatch_clis_are_not_blocked
    assert_allowed "ruby ~/.claude/cf/bin/change_autopilot.rb end --reason done"
    assert_allowed "ruby ~/.claude/cf/bin/change_autopilot.rb status --json"
    assert_allowed "ruby ~/.claude/cf/bin/change_prod_request.rb dispatch 11111111-2222-4333-8444-555555555555 --config CHANGE.md"
    assert_allowed "git fetch origin +refs/cf-prod/*:refs/cf-prod/*"
  end

  def test_denies_writes_to_guarded_state_refs
    assert_denied "git push origin refs/cf-prod/approvals/1234:refs/cf-prod/approvals/1234"
    assert_denied "git push origin :refs/cf-prod/claims/1234"
    assert_denied "git push origin refs/cf-prod/requests/1234:refs/cf-prod/requests/1234"
    assert_denied "git update-ref refs/cf-prod/lock/production abc"
    assert_denied "gh api -X POST repos/o/r/git/refs -f ref=refs/cf-prod/journal/1 -f sha=abc"
    assert_denied "gh api -X DELETE repos/o/r/git/refs/cf-prod/claims/1234"
    assert_denied "gh api repos/o/r/git/refs -f ref=refs/cf-prod/approvals/1 -f sha=abc"
  end

  def test_denies_git_global_options_variables_and_streams_that_hide_the_ref
    assert_denied "git -C . push origin x:refs/cf-prod/approvals/abc"
    assert_denied "git -c k=v push origin x:refs/cf-prod/approvals/abc"
    assert_denied "git --git-dir .git push origin x:refs/cf-prod/claims/abc"
    assert_denied "git --git-dir=.git -C . -c a=b push origin x:refs/cf-prod/lock/abc"
    assert_denied "git --no-pager update-ref refs/cf-prod/journal/abc HEAD"
    assert_denied "echo 'update refs/cf-prod/claims/abc HEAD' | git update-ref --stdin"
    assert_denied "R=approvals; git push origin x:refs/cf-prod/$R/abc"
    assert_denied "git -c alias.p=push p origin x:refs/cf-prod/approvals/abc"
    assert_denied "git fast-import < cf-prod.stream"
    assert_denied "git replace abc def # cf-prod"
    assert_denied "git-receive-pack cf-prod.git"
    assert_denied "git send-pack origin refs/cf-prod/claims/abc"
    assert_denied "bash -c 'git -C . push origin x:refs/cf-prod/approvals/abc'"
    assert_denied "R=approvals; gh api -X POST repos/o/r/git/refs -f ref=refs/cf-prod/$R/x -f sha=abc"
    assert_denied "gh api repos/o/r/git/refs -f ref=refs/cf-prod/requests/x -f sha=abc"
  end

  def test_stream_writes_are_denied_in_a_repo_with_cf_prod_configured_only
    Dir.mktmpdir do |dir|
      assert_allowed "git update-ref --stdin < cmds", cwd: dir
      assert_allowed "git fast-import < x", cwd: dir
      FileUtils.mkdir_p(File.join(dir, ".github/workflows"))
      File.write(File.join(dir, ".github/workflows/cf-prod.yml"), "name: cf-prod\n")
      sub = File.join(dir, "deep", "er")
      FileUtils.mkdir_p(sub)
      assert_equal "deny", decide("git update-ref --stdin < cmds", cwd: dir)
      assert_equal "deny", decide("git -C . fast-import < x", cwd: sub)
      assert_nil decide("git update-ref refs/heads/x HEAD", cwd: dir)
      assert_nil decide("git status", cwd: dir)
    end
  end

  def test_allows_the_agent_tools_and_reads
    assert_allowed "git log refs/cf-prod/requests/1234"
    assert_allowed "git -C . fetch origin refs/cf-prod/requests/1234"
    assert_allowed "ruby ~/.claude/cf/bin/change_prod_request.rb create --op rotate_tenant_key --profile staging --config CHANGE.md"
    assert_allowed "gh api repos/o/r/git/refs/cf-prod/approvals/1234"
    assert_allowed "git fetch origin 'refs/cf-prod/*:refs/cf-prod/*'"
    assert_allowed "gh workflow run cf-prod.yml -f request_id=abc"
  end

  def test_ignores_unrelated_commands_and_tools
    assert_allowed "git status"
    assert_allowed "ls"
    assert_allowed "echo change_prod_approve.rb", tool: "Read"
  end

  def test_an_unparseable_command_naming_an_approval_path_is_denied
    assert_denied "ruby change_prod_approve.rb 'unterminated"
  end

  def test_a_quoted_mention_in_a_commit_message_is_not_an_invocation
    assert_allowed "git commit -m 'document pending_deployments handling'"
    assert_allowed "gh pr create --title t --body 'mentions refs/cf-prod/claims'"
  end

  def test_fails_silent_on_a_malformed_event
    io = StringIO.new
    ProdApprovalGuard.new({ "tool_name" => "Bash", "tool_input" => "nope" }).emit(io)
    assert_empty io.string
    ProdApprovalGuard.new({}).emit(io)
    assert_empty io.string
  end

  def test_the_deny_reason_says_a_human_must_do_it
    io = StringIO.new
    ProdApprovalGuard.new({ "tool_name" => "Bash", "tool_input" => { "command" => "ruby change_prod_approve.rb x" } }).emit(io)
    reason = JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecisionReason")
    assert_includes reason, "human-only"
  end
end
