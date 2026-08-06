#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'hook_event'
require_relative 'change_policy'
require_relative 'change_gate_check'
require_relative 'change_tag_refs'
require_relative 'guarded_command'

# PreToolUse hook: gates publishing a protected release tag - a `git push`
# that would publish a matching tag, or `gh release create` - on a
# comprehensive cf:change run having passed for the exact commit the tag
# would point at, plus any `require_trunk_ancestor` / `require_prior_tag` rule
# the repo's CHANGE.md states. Same shape as change_merge_guard.rb, and shares
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
    policy = ChangePolicy.for_repo(root) or return nil
    return nil if policy.protected_tag_patterns.empty?

    refs = ChangeTagRefs.for_command(command, root)
    return nil if refs.empty?

    reasons = refs.flat_map { |tag, sha| tag_violations(policy, tag, sha, root) }
    reasons.empty? ? nil : reasons.join(' ')
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
    profile = policy.profile_for_rule(rule)
    apps = ChangeGateCheck.required_apps(root, policy.apps_for_rule(rule))
    check = ChangeGateCheck.new(sha: sha, profile: profile, apps: apps)
    return nil if check.satisfied?

    conditions = policy.admin_bypass_conditions
    note = conditions.empty? ? '' : "Repo policy: #{conditions}. "
    target = profile ? "the '#{profile}' profile" : 'a comprehensive'
    "publishing tag '#{tag}' is gated: no passing #{target} cf:change run recorded for commit " \
      "#{sha[0, 12]}#{check.missing_apps_clause}. #{rerun_hint(check, tag)} #{note}#{ChangeGateCheck.escape_note}"
  end

  def rerun_hint(check, tag)
    extra = check.flags.reject { |flag| flag.start_with?('--profile') }
    suffix = extra.empty? ? '' : " #{extra.join(' ')}"
    "Run /cf:change against this commit first with --for-tag #{tag}#{suffix}."
  end

  # `require_trunk_ancestor: main` (0.9.0-alpha.1): the tagged commit must be
  # an ancestor of (or equal to) the named branch, checked against the
  # remote-tracking ref when one exists (a fresher signal than a possibly
  # stale local branch). Fails open (nil) whenever the branch cannot be
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

  def resolve_branch_ref(branch, root)
    remote_ref = "origin/#{branch}"
    return remote_ref if ref_exists?(remote_ref, root)
    return branch if ref_exists?(branch, root)

    nil
  end

  def ref_exists?(ref, root)
    _out, status = Open3.capture2e('git', '-C', root, 'rev-parse', '--verify', '--quiet', ref)
    status.success?
  rescue StandardError
    false
  end

  # `require_prior_tag: "staging/v*"` (0.9.0-alpha.1): some already-published
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
