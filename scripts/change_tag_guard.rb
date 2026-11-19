#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'hook_event'
require_relative 'change_policy'
require_relative 'change_gate_check'
require_relative 'change_tag_refs'
require_relative 'guarded_command'

# PreToolUse hook: gates publishing a protected release tag on a passing
# comprehensive cf:change run for its commit. Publishing is a `git push` that
# would publish a matching tag, or `gh release create`; the run must have passed
# for the exact commit the tag would point at, plus any `require_trunk_ancestor`
# / `require_prior_tag` rule the repo's CHANGE.md states. Same shape as change_merge_guard.rb, and shares
# its gate question via ChangeGateCheck: reads the Bash command text, denies
# with a reason, fails open on anything it cannot determine, bypassable the
# same way (CF_ALLOW_UNGATED_MERGE=1, or a change_override.rb record) - one
# escape hatch shared by both guards, not a second one for tags.
#
# A local `git tag` is free and private; this hook never fires on it. The
# gated moment is publication - the tag becoming visible to whatever deploys
# from it - matching change_merge_guard.rb's own trigger (a real merge, not a
# local commit). A repo with no CHANGE.md, or a CHANGE.md with no tag rules,
# is entirely unaffected.
class ChangeTagGuard
  EVENT = 'PreToolUse'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return if ENV['CF_ALLOW_UNGATED_MERGE'] == '1'
    return unless @event['tool_name'] == 'Bash'
    return unless GuardedCommand.tag_push?(command) || GuardedCommand.release_create?(command)

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
  # facts (no repo, no CHANGE.md, no tag rules at all, an unresolvable ref)
  # fails open: an advisory guard must not wedge a release on an inability to
  # check.
  def violation
    root = repo_root or return nil
    refs = ChangeTagRefs.for_command(command, root)
    return nil if refs.empty?

    source = policy_source(root)
    return ambiguous_violation(root) if source == :ambiguous

    trunk = source && default_branch(source)
    policy = trunk ? base_policy(source, trunk) : :unreadable
    return unreadable_violation(root, trunk) if policy == :unreadable
    return nil if policy.nil?
    return nil if policy.protected_tag_patterns.empty?

    @source = source
    reasons = refs.flat_map { |tag, sha| tag_violations(policy, tag, sha, root) }
    reasons.empty? ? nil : reasons.join(' ')
  end

  # The repository this command publishes the tag to, resolved by
  # ChangePolicy::Source alone (#553): the `git push <repository>` argument
  # (a remote name or URL; the branch's push remote, else origin, when
  # absent), or `gh release create`'s --repo/-R (else the default push
  # remote). nil when the destination names no remote or URL, so a governed
  # repo fails closed on it.
  def policy_source(root)
    return release_source(root) if GuardedCommand.release_create?(command)

    ChangePolicy::Source.for_destination(root, push_destination)
  end

  def push_destination
    toks = GuardedCommand.tokens(command)
    rest = toks[(toks.index('push') + 1)..] || []
    idx = rest.index('--repo')
    return rest[idx + 1] if idx

    flag = rest.find { |token| token.start_with?('--repo=') }
    return flag.delete_prefix('--repo=') if flag

    rest.find { |token| !token.start_with?('-') }
  end

  def release_source(root)
    toks = GuardedCommand.tokens(command)
    idx = toks.index { |t| %w[-R --repo].include?(t) }
    value = idx ? toks[idx + 1] : toks.find { |t| t.start_with?('--repo=') }&.delete_prefix('--repo=')
    return default_release_source(root) unless value

    parts = value.sub(%r{\Ahttps?://}, '').split('/')
    parts.unshift('github.com') if parts.size == 2
    parts.size == 3 ? ChangePolicy::Source.for_identity(root, parts.map(&:downcase)) : nil
  end

  # Without --repo, gh releases to its own default repository. When
  # `gh repo set-default` names a remote other than the push remote, the
  # destination is ambiguous: :ambiguous, so a governed repo denies and asks
  # for --repo rather than guess (full gh default resolution is follow-up work).
  def default_release_source(root)
    gh_remote = ChangePolicy::Source.gh_default_remote(root)
    push_remote = ChangePolicy::Source.default_push_remote(root)
    return :ambiguous if gh_remote && gh_remote != push_remote
    # gh releases to a remote's repository, not its pushurl; when they differ,
    # the git push destination is not gh's.
    return :ambiguous if ChangePolicy::Source.split_push?(root, push_remote)

    ChangePolicy::Source.for_destination(root, nil)
  end

  def ambiguous_violation(root)
    return nil unless File.exist?(File.join(root, 'CHANGE.md'))

    "publishing this release is gated: `gh release create` has no --repo and `gh repo set-default` names a " \
      "different remote than the push remote (or that remote has a separate pushurl), so the destination " \
      "repository is ambiguous. Pass --repo OWNER/REPO. " \
      "#{ChangeGateCheck.escape_note}"
  end

  # The gating policy as CHANGE.md stands on the destination repository's
  # default branch, never the working tree (#553). The branch name is asked
  # of that repository itself, not of origin or CHANGE.md, so neither a fork
  # origin nor a PR's own copy can redirect the guard.
  def default_branch(source) = source.default_branch

  def base_policy(source, trunk)
    source.policy(trunk)
  rescue ChangePolicy::Unreadable
    :unreadable
  end

  def unreadable_violation(root, trunk)
    return nil unless File.exist?(File.join(root, 'CHANGE.md'))

    "publishing this tag is gated: the default branch's ('#{trunk || 'unresolved'}') CHANGE.md could not be read " \
      "(fetch or git show failed), so this guard fails closed rather than judge the tag " \
      "by the working tree's own copy. #{ChangeGateCheck.escape_note}"
  end

  # Every tag rule matching this tag must independently be satisfied (the
  # platform's fail-closed reading for overlapping patterns, ChangePolicy's
  # own doc comment on #tag_rules_for). For each matching rule, the gate check
  # is asked first; a rule that already fails the gate does not also need its
  # ancestor/prior-tag conditions spelled out in the same deny.
  def tag_violations(policy, tag, sha, root)
    policy.tag_rules_for(tag).filter_map do |_pattern, rule|
      rule_violation(policy, tag, rule, sha, root)
    end
  end

  def rule_violation(policy, tag, rule, sha, root)
    gate_violation(policy, tag, rule, sha, root) ||
      ancestor_violation(policy, tag, rule, sha, root) ||
      prior_tag_violation(policy, tag, rule, sha, root)
  end

  # Shared gate check: a comprehensive cf:change run must have passed for the
  # tagged commit, scoped to the rule's named profile and (0.4.0 monorepo
  # mode) its required app set, exactly as change_merge_guard.rb asks the same
  # question for a merge. ChangeGateCheck is the shared decision object;
  # everything here is deny-wording specific to a tag publish.
  def gate_violation(policy, tag, rule, sha, root)
    return nil unless ChangeGateCheck.required?(policy, base: tag, kind: :tag)

    profile = policy.profile_for_rule(rule)
    apps = ChangeGateCheck.required_apps(root, policy.apps_for_rule(rule))
    check = ChangeGateCheck.new(sha: sha, profile: profile, apps: apps, root: root)
    return nil if check.satisfied?

    conditions = policy.admin_bypass_conditions
    note = conditions.empty? ? '' : "Repo policy: #{conditions}. "
    target = profile ? "the '#{profile}' profile" : 'a comprehensive'
    "publishing tag '#{tag}' is gated: no passing #{target} cf:change run recorded for commit " \
      "#{sha[0, 12]}#{check.missing_apps_clause}#{check.trust_clause}. #{rerun_hint(check, tag)} #{note}#{ChangeGateCheck.escape_note}"
  end

  def rerun_hint(check, tag)
    extra = check.flags.reject { |flag| flag.start_with?('--profile') }
    suffix = extra.empty? ? '' : " #{extra.join(' ')}"
    "Run /cf:change against this commit first with --for-tag #{tag}#{suffix}."
  end

  # `require_trunk_ancestor: main` (0.9.0): the tagged commit must be
  # an ancestor of (or equal to) the named branch, checked against the
  # destination repository's copy when it can be fetched (a fresher signal
  # than a possibly stale local branch). Fails open (nil) whenever the branch cannot be
  # resolved at all, rather than deny on a fact the guard could not establish.
  def ancestor_violation(policy, tag, rule, sha, root)
    branch = policy.require_trunk_ancestor_for_rule(rule)
    return nil unless branch

    ancestor = trunk_ancestor?(sha, branch, root)
    return nil if ancestor.nil? || ancestor

    "publishing tag '#{tag}' is gated: commit #{sha[0, 12]} is not an ancestor of '#{branch}'. " \
      "Merge to '#{branch}' first, then tag. #{ChangeGateCheck.escape_note}"
  end

  def trunk_ancestor?(sha, branch, root)
    ref = resolve_branch_ref(branch, root)
    return nil unless ref

    _out, status = Open3.capture2e('git', '-C', root, 'merge-base', '--is-ancestor', sha, ref)
    return status.success? if [ 0, 1 ].include?(status.exitstatus)

    nil
  rescue StandardError
    nil
  end

  # The branch as the destination repository has it (fetched through the
  # same ChangePolicy::Source as the policy), else the local branch.
  def resolve_branch_ref(branch, root)
    fetched = @source&.fetch(branch)
    return fetched if fetched
    return branch if ref_exists?(branch, root)

    nil
  end

  def ref_exists?(ref, root)
    _out, status = Open3.capture2e('git', '-C', root, 'rev-parse', '--verify', '--quiet', ref)
    status.success?
  rescue StandardError
    false
  end

  # `require_prior_tag: "staging/v*"` (0.9.0): some already-published
  # tag matching this glob must already point at the same commit. Fails open
  # when `git tag --points-at` cannot even run.
  def prior_tag_violation(policy, tag, rule, sha, root)
    glob = policy.require_prior_tag_for_rule(rule)
    return nil unless glob

    prior_tags = points_at_tags(sha, root)
    return nil if prior_tags.nil?
    return nil if prior_tags.any? { |name| File.fnmatch(glob, name, File::FNM_PATHNAME) }

    "publishing tag '#{tag}' is gated: no tag matching '#{glob}' points at commit " \
      "#{sha[0, 12]}. Release to that environment first, then tag. #{ChangeGateCheck.escape_note}"
  end

  def points_at_tags(sha, root)
    out, status = Open3.capture2e('git', '-C', root, 'tag', '--points-at', sha)
    return nil unless status.success?

    out.each_line.map(&:strip).reject(&:empty?)
  rescue StandardError
    nil
  end

  def repo_root
    out, status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

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

ChangeTagGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
