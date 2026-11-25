#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'hook_event'
require_relative 'change_policy'
require_relative 'change_gate_check'
require_relative 'change_override_store'
require_relative 'guarded_command'
require_relative 'change_pr_facts'
require_relative 'change_carve_out_store'
require_relative 'change_autopilot'
require_relative 'cf_project_identity'
require_relative 'approval_console/canonical'
require_relative 'approval_console/local_store'
require_relative 'approval_console/proof_check'

# PreToolUse hook: gates a `gh pr merge` into a protected branch on a
# comprehensive cf:change run. The branch is a repo's staging/production or
# whatever CHANGE.md names, the run must have passed for the PR's head commit,
# and the repo's own admin-bypass policy from CHANGE.md is enforced. Same shape as merge_mode_guard: it
# reads the Bash command text and denies with a reason, a loud guardrail rather
# than a sandbox, bypassable (CF_ALLOW_UNGATED_MERGE=1) for the genuine
# exception.
#
# One file informs the decision: the repo-root CHANGE.md, whose `change_policy:`
# frontmatter block this hook reads. A repo with no CHANGE.md is ungoverned and
# merges freely; presence of CHANGE.md is the opt-in. So this hook never blocks
# an unrelated repo on the machine, only one that has chosen change-fabric
# governance.
class ChangeMergeGuard
  EVENT = 'PreToolUse'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return if ENV['CF_ALLOW_UNGATED_MERGE'] == '1'
    return unless @event['tool_name'] == 'Bash'
    return unless GuardedCommand.merge?(command)

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
    pr = pr_facts or return nil
    base, sha, url = pr
    policy = base_policy(root, base, url)
    return unreadable_violation(root, base) if policy == :unreadable
    return nil if policy.nil?

    carve_out = carve_out_violation(policy, base, sha, url)
    return carve_out if carve_out
    return nil unless policy.protects?(base)
    # An override counts only when its proof stands (ChangeGateCheck#overridden?).
    return nil if ChangeGateCheck.new(sha: sha, profile: policy.profile_for(base), root: root,
                                      proof_level: policy.require_approval_proof,
                                      proof_pins: policy.approval_pins, scope: 'merge').overridden?

    admin?(command) ? admin_violation(policy, base, sha) : normal_violation(policy, base, sha)
  end

  # The policy as CHANGE.md stands on the base branch, never the PR's own
  # working tree (#553): a PR cannot loosen the rule it is judged by. Fetches
  # the base first so a stale local remote-tracking ref never reads as fresh.
  # Returns :unreadable rather than letting ChangePolicy::Unreadable escape,
  # so `violation` can decide fail-open-vs-fail-closed against the
  # working-tree CHANGE.md's mere presence.
  #
  # The policy comes from the repository that owns the PR (host/owner/repo
  # from the PR's URL, resolved by ChangePolicy::Source), not blindly from
  # `origin`: in a fork checkout gh's default repository can be the upstream
  # while origin is the fork, and a GitHub Enterprise PR must never be judged
  # by a github.com remote sharing its owner/repo.
  def base_policy(root, base, url = nil)
    ChangePolicy::Source.for_pr_url(root, url).policy(base)
  rescue ChangePolicy::Unreadable
    :unreadable
  end

  # A PR whose changed files (both names of a rename) match the base policy's
  # `carve_out_paths` merges only at a phone-approved head: a ChangeCarveOutStore
  # record for this repo, PR and exact head, its receipt passing the carve-out
  # row of the claim table (passkey level, signed files and base equal to the
  # recomputed ones) and under 24h old now, and `--match-head-commit <head>` on
  # the merge. Fails closed on every gh or store error, but only for a policy
  # that lists carve-out paths; a repo without the list is unaffected. A
  # standing override does not waive it.
  def carve_out_violation(policy, base, sha, url)
    return nil if policy.carve_out_paths.empty?

    files = changed_files(url)
    hits = files.select { |file| policy.carve_out?(file) }
    return nil if hits.empty?

    problem = carve_out_problem(policy, base, sha, url, files)
    return nil unless problem

    "this PR is a carve-out (#{hits.first(3).join(', ')}#{hits.size > 3 ? ", and #{hits.size - 3} more" : ''}): #{problem} " \
      "Request Patrick's phone approval of the exact head with approval_console.rb request " \
      "--type carve-out --pr-url #{url || '<pr-url>'} --summary <what and why>, add --no-wait, post the link, then start approval_console.rb record <id> as a background task (run_in_background) so the session is woken on the decision (never ask the human to type approved), then merge with " \
      "--match-head-commit #{sha}. #{escape_note}"
  rescue StandardError => e
    "this repo lists carve-out paths and the PR could not be classified (#{e.message}); the guard fails closed. #{escape_note}"
  end

  def carve_out_problem(policy, base, sha, url, files)
    return "a carve-out must merge now, not with --auto: auto-merge lands a later head than the one approved." if GuardedCommand.tokens(command).include?('--auto')
    return "the merge must carry --match-head-commit #{sha} (the head the approval binds)." unless match_head_commit(command) == sha
    return nil if autopilot_waives?(files, sha, url)

    repo = ChangePrFacts.repo_id(url)
    number = ChangePrFacts.parse_url(url).last
    record = carve_out_store.lookup(repo: repo, pr: number, sha: sha)
    return "no phone-approved carve-out is recorded for head #{sha[0, 12]}." unless record

    receipt_problem(record['proof'], policy, repo: repo, sha: sha, url: url, base: base, files: files)
  end

  def receipt_problem(proof, policy, repo:, sha:, url:, base:, files:)
    signed = ApprovalConsole::Canonical.parse(proof.is_a?(Hash) ? proof['body'] : nil)
    expected = { 'type' => 'carve-out', 'repo' => repo, 'sha' => sha, 'profile' => signed['profile'], 'summary' => signed['summary'],
                 'pr_url' => url, 'pr_title' => signed['pr_title'], 'base' => base, 'files' => files }
    check = ApprovalConsole::ProofCheck.new(level: 'passkey', store: proof_store, pins: policy.approval_pins, now: Time.now)
    problem = check.receipt_problem(proof, expected)
    return "the recorded carve-out receipt is refused: #{problem}." if problem
    return nil if ApprovalConsole::ProofCheck.fresh?(proof, at: Time.now)

    'the carve-out receipt is 24h old or older (or dated in the future); request a new approval.'
  end

  # An active autopilot naming carve_out stands in for the per-head tap, but
  # only for this repo's own PR and never when any changed file is a locked
  # path (the guards, the autopilot code, CHANGE.md, ...). --auto and
  # --match-head-commit were already enforced above; cf:change still gates.
  def autopilot_waives?(files, sha, url)
    return false if files.any? { |file| ChangeAutopilot.locked_path?(file) }

    root = repo_root or return false
    return false unless ChangePrFacts.repo_id(url) == CfProjectIdentity.for(root).id

    !autopilot_waive('carve_out', root, "PR #{url} at #{sha}").nil?
  end

  def autopilot_waive(gate, root, detail)
    ChangeAutopilot.waive!(gate, project: root, guard: 'change_merge_guard', detail: detail, command: command, session: @event['session_id'])
  end

  def changed_files(url) = ChangePrFacts.files(url)
  def carve_out_store = ChangeCarveOutStore.new
  def proof_store = ApprovalConsole::LocalStore.new

  # The sha after `--match-head-commit` (or `=`) on the merge command, or nil.
  def match_head_commit(cmd)
    tokens = GuardedCommand.tokens(cmd)
    idx = tokens.index('--match-head-commit')
    return tokens[idx + 1] if idx

    tokens.find { |token| token.start_with?('--match-head-commit=') }&.split('=', 2)&.last
  end

  # Fail-closed only when this repo is otherwise governed at all (a
  # working-tree CHANGE.md exists); an unrelated repo that never opted into
  # change-fabric must still merge freely even if, say, the base ref cannot be
  # fetched for some unrelated network reason.
  def unreadable_violation(root, base)
    return nil unless File.exist?(File.join(root, 'CHANGE.md'))

    "merge into '#{base}' is gated: the base branch's CHANGE.md could not be read " \
      "(fetch or git show failed), so this guard fails closed rather than judge the merge " \
      "by the PR's own copy. #{escape_note}"
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
    return nil unless ChangeGateCheck.required?(policy, base: base, kind: :pr_merge)

    gate_violation(base, sha, policy, kind: 'admin-bypass merge')
  end

  def normal_violation(policy, base, sha)
    return nil unless policy.require_change_pass?(base)
    return nil unless ChangeGateCheck.required?(policy, base: base, kind: :pr_merge)

    gate_violation(base, sha, policy, kind: 'merge')
  end

  # Shared gate check: a comprehensive cf:change run must have passed for this
  # exact head SHA, scoped to the branch's named profile (v0.2.0) when its
  # promotion rule names one, and (0.4.0) to the branch's required app set in a
  # monorepo -- the policy's own promotion.<branch>.apps list, or every
  # registered enabled app when that is absent. Single-app mode asks the same
  # question it always has: `apps` stays nil, so ChangeGateCheck#satisfied?
  # falls back to its 0.3.1 top-level scope/status check. The gate question
  # itself is asked by ChangeGateCheck, shared with change_tag_guard.rb; only
  # the deny wording below is specific to a merge.
  def gate_violation(base, sha, policy, kind:)
    profile = policy.profile_for(base)
    apps = ChangeGateCheck.required_apps(repo_root, policy.apps_for(base))
    check = ChangeGateCheck.new(sha: sha, profile: profile, apps: apps, root: repo_root, proof_level: policy.require_approval_proof,
                                      proof_pins: policy.approval_pins, scope: 'merge')
    return check.overridden? ? nil : testcases_violation(base, sha, policy, check, kind: kind) if check.satisfied?

    conditions = policy.admin_bypass_conditions
    note = conditions.empty? ? '' : "Repo policy: #{conditions}. "
    target = profile ? "the '#{profile}' profile" : 'a comprehensive'
    "#{kind} into '#{base}' is gated (gate.require_on: #{policy.gate_require_on}): " \
      "no passing #{target} cf:change run recorded for head " \
      "#{sha[0, 12]}#{check.missing_apps_clause}#{check.trust_clause}. #{rerun_hint(check)} " \
      "#{note}#{ChangeGateCheck.escape_note}"
  end

  # The second, narrower question a branch may ask (0.10.0): the run passed
  # overall, but did the regression lane itself pass? A comprehensive run whose
  # testcases lane never ran satisfies `require_change_pass` and answers
  # nothing about the repo's committed cases, which is exactly the gap a repo
  # setting `require_testcases: true` is closing.
  def testcases_violation(base, sha, policy, check, kind:)
    return nil unless policy.require_testcases?(base)
    return nil if check.store.lane_passed?('testcases', apps: check.apps)

    "#{kind} into '#{base}' is gated: the recorded cf:change run for head #{sha[0, 12]} carries no " \
      "passing testcases lane, and this branch's promotion rule sets require_testcases. " \
      "Run /cf:change against this PR with the testcases lane enabled. #{escape_note}"
  end

  def rerun_hint(check)
    suffix = check.flags.empty? ? '' : " with #{check.flags.join(' ')}"
    "Run /cf:change against this PR first#{suffix}."
  end

  # CF_ALLOW_UNGATED_MERGE=1 only works if it was exported before this
  # session's own hook process started, which an agent mid-session cannot
  # arrange. The reachable path: a human runs change_override.rb themselves,
  # from their own real terminal (it refuses without one), to record an
  # auditable, sha-scoped override the guard checks in #violation above.
  def escape_note = ChangeGateCheck.escape_note

  def admin?(cmd) = GuardedCommand.tokens(cmd).include?('--admin')

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
    args += [ '--json', 'baseRefName,headRefOid,url', '-q', '.baseRefName + "\t" + .headRefOid + "\t" + .url' ]
    out, _err, status = Open3.capture3(*args)
    return nil unless status.success?

    base, sha, url = out.strip.split("\t", 3)
    base && sha ? [ base, sha, url ] : nil
  rescue StandardError
    nil
  end

  # The first positional argument to `pr merge` (a number, URL, or branch), or
  # nil for a bare `gh pr merge` that targets the current branch's PR. The
  # value of a flag such as `--match-head-commit <sha>` is not that argument.
  def merge_ref(cmd) = ChangePrFacts.merge_ref(cmd)

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: "[cf:change] #{reason}"
      }
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('change_merge_guard', event) { ChangeMergeGuard.new(event).emit }
end
