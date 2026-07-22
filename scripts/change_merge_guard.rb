#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'hook_event'
require_relative 'change_policy'
require_relative 'change_gate_store'

# PreToolUse hook: gates a `gh pr merge` that lands into a repo's protected
# branch (staging/production, or whatever CHANGE.md names) on a comprehensive
# pst:change run having passed for the PR's head commit, and enforces the repo's
# own admin-bypass policy from CHANGE.md. Same shape as merge_mode_guard: it
# reads the Bash command text and denies with a reason, a loud guardrail rather
# than a sandbox, bypassable (PST_ALLOW_UNGATED_MERGE=1) for the genuine
# exception.
#
# One file informs the decision: the repo-root CHANGE.md, whose `change_policy:`
# frontmatter block this hook reads. A repo with no CHANGE.md is ungoverned and
# merges freely; presence of CHANGE.md is the opt-in. So this hook never blocks
# an unrelated repo on the machine, only one that has chosen change-fabric
# governance.
class ChangeMergeGuard
  EVENT = 'PreToolUse'
  MERGE = /\bgh\b[^&|;]*\bpr\b[^&|;]*\bmerge\b/
  ADMIN = /\s--admin\b/

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return if ENV['PST_ALLOW_UNGATED_MERGE'] == '1'
    return unless @event['tool_name'] == 'Bash'
    return unless command.match?(MERGE)

    reason = violation
    io.puts(JSON.generate(deny(reason))) if reason
  rescue StandardError
    nil
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  # The deny reason, or nil to allow. Every branch that cannot determine the
  # facts (no repo, no CHANGE.md, unreadable PR) fails open: an advisory guard
  # must not wedge a merge on an inability to check.
  def violation
    root = repo_root or return nil
    policy = ChangePolicy.for_repo(root) or return nil
    pr = pr_facts or return nil
    base, sha = pr
    return nil unless policy.protects?(base)

    admin?(command) ? admin_violation(policy, base, sha) : normal_violation(policy, base, sha)
  end

  # An admin-bypass merge (`--admin`): first the repo must permit the practice at
  # all, then, if it does, the change gate still applies unless the repo waived
  # it for bypasses.
  def admin_violation(policy, base, sha)
    unless policy.admin_bypass_allowed?
      return "admin-bypass merge into '#{base}' is not permitted by this repo's CHANGE.md. " \
             "Merge through the normal reviewed path. #{escape_note}"
    end
    return nil unless policy.admin_bypass_requires_change_pass?

    gate_violation(base, sha, policy, kind: 'admin-bypass merge')
  end

  def normal_violation(policy, base, sha)
    return nil unless policy.require_change_pass?(base)

    gate_violation(base, sha, policy, kind: 'merge')
  end

  # Shared gate check: a comprehensive pst:change run must have passed for this
  # exact head SHA.
  def gate_violation(base, sha, policy, kind:)
    return nil if ChangeGateStore.new(sha).comprehensive_pass?

    conditions = policy.admin_bypass_conditions
    note = conditions.empty? ? '' : "Repo policy: #{conditions}. "
    "#{kind} into '#{base}' is gated: no passing comprehensive pst:change run recorded for head " \
      "#{sha[0, 12]}. Run /pst:change against this PR first. #{note}#{escape_note}"
  end

  def escape_note = 'Set PST_ALLOW_UNGATED_MERGE=1 to override for a genuine exception.'

  def admin?(cmd) = cmd.match?(ADMIN)

  def repo_root
    out, status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  # [base_branch, head_sha] for the PR the command targets: an explicit
  # number/url/branch argument, or the current branch's PR when bare. Uses the
  # gh CLI, the same tool the merge command itself uses, so if gh cannot resolve
  # the PR the merge would fail anyway and failing open here is harmless.
  def pr_facts
    ref = merge_ref(command)
    args = [ 'gh', 'pr', 'view' ]
    args << ref if ref
    args += [ '--json', 'baseRefName,headRefOid', '-q', '.baseRefName + "\t" + .headRefOid' ]
    out, status = Open3.capture2e(*args)
    return nil unless status.success?

    base, sha = out.strip.split("\t", 2)
    base && sha ? [ base, sha ] : nil
  rescue StandardError
    nil
  end

  # The first positional argument to `pr merge` (a number, URL, or branch), or
  # nil for a bare `gh pr merge` that targets the current branch's PR.
  def merge_ref(cmd)
    tokens = cmd.split
    idx = tokens.index('merge')
    return nil unless idx

    tokens[(idx + 1)..].find { |token| !token.start_with?('-') }
  end

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: "[pst:change] #{reason}"
      }
    }
  end
end

ChangeMergeGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
