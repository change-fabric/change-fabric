#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require_relative 'change_frontmatter'

# Reads the `change_policy:` block from a repo's CHANGE.md, the single
# change-fabric file. CHANGE.md's prose body is the governance FAQ a human and an
# agent both read (git flow, PR expectations, when admin-bypass merging is
# acceptable), but a hook cannot act on prose, so the machine-checkable subset
# lives in a `change_policy:` YAML frontmatter block, alongside the
# `change_config:` block the audit lanes read. The body is the source of truth a
# person reads; the frontmatter is the same policy stated in a form the merge
# gate can enforce, and the body is expected to explain it.
#
# Presence of CHANGE.md is itself the signal that a repo has opted into
# change-fabric gating. A repo with no CHANGE.md is simply not governed by the
# merge gate, so nothing here ever manufactures a policy for an ungoverned repo:
# `for_repo` returns nil when the file is absent.
class ChangePolicy
  DEFAULT_PROTECTED = %w[staging production].freeze

  # Prefixes that disambiguate a promotion: key. A git refname cannot contain
  # ':' (git check-ref-format rejects it), so these are provably unambiguous
  # against every legal branch name; no repo can be broken by the reservation.
  # tag: marks a tag glob, gated at tag-push time (a later phase's
  # enforcement). branch: is an explicit synonym for an unprefixed key;
  # nothing requires it, it exists for a repo that wants symmetry.
  TAG_PREFIX = 'tag:'
  BRANCH_PREFIX = 'branch:'

  # Loads the policy from a repo root's CHANGE.md. Returns nil when no CHANGE.md
  # exists (ungoverned repo).
  def self.for_repo(root)
    path = File.join(root, 'CHANGE.md')
    return nil unless File.exist?(path)

    new(ChangeFrontmatter.parse_file(path)['change_policy'], path)
  rescue StandardError
    # A malformed CHANGE.md must not wedge every merge; fall back to the
    # conservative default policy so the gate still protects the named branches.
    new({}, path)
  end

  def initialize(policy, path)
    @policy = policy.is_a?(Hash) ? policy : {}
    @path = path
  end

  def path = @path

  # Branches whose merges are gated. The union of any explicit
  # `protected_branches` list, every branch named under `promotion:` (a
  # `tag:`-prefixed key never contributes here, only to `protected_tag_patterns`
  # below), and the unprefixed/`branch:` entries of `protected_refs`. So a
  # repo that describes its staging/production promotion rules gets those
  # branches gated without restating them. Anything not listed merges freely.
  # `DEFAULT_PROTECTED` applies only when this branch set is empty, so a trunk
  # repo declaring only tag rules (and, say, `promotion.main`) does not
  # silently inherit the [staging, production] fallback meant for a repo that
  # configured nothing at all.
  def protected_branches
    listed = Array(@policy['protected_branches']).map(&:to_s)
    promoted = branch_promotion.keys
    ref_branches = protected_refs.reject { |ref| ref.start_with?(TAG_PREFIX) }.map { |ref| strip_branch_prefix(ref) }
    branches = (listed + promoted + ref_branches).uniq
    branches.empty? ? DEFAULT_PROTECTED : branches
  end

  def protects?(branch) = protected_branches.include?(branch.to_s)

  # Tag patterns (globs) whose publication is gated: every `tag:`-prefixed
  # `promotion:` key plus the `tag:`-prefixed entries of `protected_refs`. No
  # default: a repo with no tag rule anywhere has no tag gating at all, unlike
  # `protected_branches`, which falls back to a conservative default. There is
  # no equivalent "sensible default tag convention" to fall back to.
  def protected_tag_patterns
    from_promotion = tag_promotion.keys
    from_refs = protected_refs.select { |ref| ref.start_with?(TAG_PREFIX) }.map { |ref| ref.delete_prefix(TAG_PREFIX) }
    (from_promotion + from_refs).uniq
  end

  # Whether any protected tag pattern fnmatches this tag name. See
  # `tag_rules_for`'s comment for the glob semantics.
  def protects_tag?(tag) = protected_tag_patterns.any? { |pattern| tag_glob_match?(pattern, tag) }

  # protected_refs (0.9.0-alpha.1): the raw list, each entry an unprefixed
  # branch name, `branch:<name>`, or `tag:<glob>`. Superset of
  # `protected_branches`, unioned with it (and with `promotion:`'s keys),
  # never replacing it.
  def protected_refs
    Array(@policy['protected_refs']).map(&:to_s)
  end

  # A normal (non-admin) merge into a protected branch needs a passing
  # comprehensive cf:change run for the head SHA unless that branch's promotion
  # rule opts out. Read per-branch so staging and production can differ.
  def require_change_pass?(branch) = require_change_pass_for_rule?(branch_promotion[branch.to_s])

  # The per-environment promotion rules block, unfiltered: every key exactly
  # as authored, branch and tag alike. Each value maps to that target's
  # answers: review_required, self_review_allowed, require_change_pass,
  # ci_gate, ci_skippable, profile, apps, environment, and (tag rules only)
  # require_trunk_ancestor/require_prior_tag. The prose body is expected to
  # expand each into a straight answer a teammate can be pointed at.
  def promotion
    block = @policy['promotion']
    block.is_a?(Hash) ? block : {}
  end

  # `promotion`, split to the branch-keyed rules only: `tag:`-prefixed keys
  # are excluded (they live in `tag_promotion` instead) and a `branch:` prefix
  # is stripped. Every existing branch-keyed accessor is rewired onto this, so
  # a `tag:` key can never make `protects?('staging')` true for a *branch*
  # named staging just because a tag pattern happens to read the same.
  def branch_promotion
    promotion.each_with_object({}) do |(key, rule), result|
      key = key.to_s
      next if key.start_with?(TAG_PREFIX)

      result[strip_branch_prefix(key)] = rule
    end
  end

  # `promotion`, split to the `tag:`-prefixed rules only, keyed by the glob
  # with the prefix stripped off.
  def tag_promotion
    promotion.each_with_object({}) do |(key, rule), result|
      key = key.to_s
      next unless key.start_with?(TAG_PREFIX)

      result[key.delete_prefix(TAG_PREFIX)] = rule
    end
  end

  # The `[pattern, rule]` pairs, in declaration order, whose tag glob fnmatches
  # this tag name. More than one may match; per the platform's fail-closed
  # reading, every matching rule must independently be satisfied, no
  # specificity ranking is invented. Uses `File.fnmatch(pattern, tag,
  # File::FNM_PATHNAME)`, so `*` never crosses a `/` (`tag:staging/v*` matches
  # `staging/v1.4.0`, not `staging/hotfix/v1.4.0`) while `**` does, matching
  # the gitignore intuition most authors already carry.
  def tag_rules_for(tag)
    tag_promotion.select { |pattern, _rule| tag_glob_match?(pattern, tag) }.to_a
  end

  # The named change_config profile (v0.2.0) whose comprehensive pass gates
  # promotion into this branch, or nil when the branch's rule does not name
  # one (the unscoped gate: any profile-less comprehensive run, matching
  # pre-0.2.0 behavior).
  def profile_for(branch) = profile_for_rule(branch_promotion[branch.to_s])

  # The change_config.apps (0.4.0) names required to gate a merge into this
  # branch, or nil meaning "every registered enabled app" (the default, and
  # also what an explicitly empty list resolves to). An empty list is never
  # treated as "gate nothing": this method is read from inside a fail-open
  # PreToolUse hook, so raising here would silently weaken the gate rather
  # than loudly reject the config; `doctor` is where an explicitly empty list
  # is reported as the setup error it actually is. Meaningless outside
  # monorepo mode, where the caller never has more than one app to ask about.
  def apps_for(branch) = apps_for_rule(branch_promotion[branch.to_s])

  # Rule-hash sibling forms of the branch-name accessors above, so a caller
  # that already matched a rule (the tag path, matching a glob rather than
  # looking up an exact key) evaluates it directly without a second lookup.
  # The branch-name forms above are unchanged and stay the ones
  # `change_merge_guard.rb` calls.
  def require_change_pass_for_rule?(rule)
    return @policy.dig('gate', 'require_change_pass') != false unless rule.is_a?(Hash)

    rule['require_change_pass'] != false
  end

  def profile_for_rule(rule)
    value = rule.is_a?(Hash) ? rule['profile'] : nil
    value.to_s.empty? ? nil : value.to_s
  end

  def apps_for_rule(rule)
    list = rule.is_a?(Hash) ? rule['apps'] : nil
    return nil unless list.is_a?(Array)

    names = list.map(&:to_s)
    names.empty? ? nil : names
  end

  # `rule['environment']`, or the pattern/key itself when unset: the human
  # label used in deny messages and `doctor` output, most useful when the
  # pattern (`tag:release/*/v*`) does not read as an environment name on its
  # own.
  def environment_for_rule(rule, pattern)
    value = rule.is_a?(Hash) ? rule['environment'] : nil
    value.to_s.empty? ? pattern.to_s : value.to_s
  end

  # Tag-rule-only fields (0.9.0-alpha.1), read as raw rule-hash accessors so
  # `doctor` can flag either appearing on a branch rule, where nothing reads
  # them. nil when unset.
  def require_trunk_ancestor_for_rule(rule)
    value = rule.is_a?(Hash) ? rule['require_trunk_ancestor'] : nil
    value.to_s.empty? ? nil : value.to_s
  end

  def require_prior_tag_for_rule(rule)
    value = rule.is_a?(Hash) ? rule['require_prior_tag'] : nil
    value.to_s.empty? ? nil : value.to_s
  end

  # Whether admin-bypass merging (`gh pr merge --admin`, skipping the normal
  # review/CI wait) is permitted at all for a protected branch. Conservative
  # default is false: a repo must state in CHANGE.md that it allows the practice.
  # Some adopting repos, whose established flow admin-merges routinely once CI
  # is green, set this true with `require_change_pass: true` so the audit gate
  # still applies.
  def admin_bypass_allowed?
    !!@policy.dig('admin_bypass', 'allowed')
  end

  # Whether an allowed admin bypass still requires the cf:change gate to have
  # passed for the head SHA. Defaults to true so "allowed" never silently means
  # "ungated".
  def admin_bypass_requires_change_pass?
    @policy.dig('admin_bypass', 'require_change_pass') != false
  end

  # The human-readable one-liner CHANGE.md gives for when an admin bypass is
  # acceptable, surfaced in a deny reason so the operator sees the repo's own
  # stated rule, not a generic message.
  def admin_bypass_conditions
    @policy.dig('admin_bypass', 'conditions').to_s
  end

  private

  def strip_branch_prefix(key) = key.start_with?(BRANCH_PREFIX) ? key.delete_prefix(BRANCH_PREFIX) : key

  def tag_glob_match?(pattern, tag) = File.fnmatch(pattern, tag.to_s, File::FNM_PATHNAME)
end
