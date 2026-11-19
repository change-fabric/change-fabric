# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../scripts/prod_approval_guard"

class ProdApprovalGuardTest < Minitest::Test
  def decide(command, tool: "Bash")
    io = StringIO.new
    ProdApprovalGuard.new({ "tool_name" => tool, "tool_input" => { "command" => command } }).emit(io)
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

  def test_denies_writes_to_guarded_state_refs
    assert_denied "git push origin refs/cf-prod/approvals/1234:refs/cf-prod/approvals/1234"
    assert_denied "git push origin :refs/cf-prod/claims/1234"
    assert_denied "git update-ref refs/cf-prod/lock/production abc"
    assert_denied "gh api -X POST repos/o/r/git/refs -f ref=refs/cf-prod/journal/1 -f sha=abc"
    assert_denied "gh api -X DELETE repos/o/r/git/refs/cf-prod/claims/1234"
    assert_denied "gh api repos/o/r/git/refs -f ref=refs/cf-prod/approvals/1 -f sha=abc"
  end

  def test_allows_the_request_ref_and_the_agent_tools
    assert_allowed "git push origin refs/cf-prod/requests/1234:refs/cf-prod/requests/1234"
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
