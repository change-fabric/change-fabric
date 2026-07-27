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
  # `protected_branches` list and every branch named under `promotion:`, so a
  # repo that describes its staging/production promotion rules gets those
  # branches gated without restating them. Anything not listed merges freely.
  def protected_branches
    listed = Array(@policy['protected_branches']).map(&:to_s)
    promoted = promotion.keys.map(&:to_s)
    branches = (listed + promoted).uniq
    branches.empty? ? DEFAULT_PROTECTED : branches
  end

  def protects?(branch) = protected_branches.include?(branch.to_s)

  # A normal (non-admin) merge into a protected branch needs a passing
  # comprehensive cf:change run for the head SHA unless that branch's promotion
  # rule opts out. Read per-branch so staging and production can differ.
  def require_change_pass?(branch)
    rule = promotion[branch.to_s]
    return @policy.dig('gate', 'require_change_pass') != false unless rule.is_a?(Hash)

    rule['require_change_pass'] != false
  end

  # The per-environment promotion rules block. Each key is a branch (staging,
  # production, or a repo's equivalent) mapping to that environment's answers:
  # review_required, self_review_allowed, require_change_pass, ci_gate,
  # ci_skippable. The prose body is expected to expand each into a straight
  # answer a teammate can be pointed at.
  def promotion
    block = @policy['promotion']
    block.is_a?(Hash) ? block : {}
  end

  # The named change_config profile (v0.2.0) whose comprehensive pass gates
  # promotion into this branch, or nil when the branch's rule does not name
  # one (the unscoped gate: any profile-less comprehensive run, matching
  # pre-0.2.0 behavior).
  def profile_for(branch)
    rule = promotion[branch.to_s]
    value = rule.is_a?(Hash) ? rule['profile'] : nil
    value.to_s.empty? ? nil : value.to_s
  end

  # The change_config.apps (0.4.0) names required to gate a merge into this
  # branch, or nil meaning "every registered enabled app" (the default, and
  # also what an explicitly empty list resolves to). An empty list is never
  # treated as "gate nothing": this method is read from inside a fail-open
  # PreToolUse hook, so raising here would silently weaken the gate rather
  # than loudly reject the config; `doctor` is where an explicitly empty list
  # is reported as the setup error it actually is. Meaningless outside
  # monorepo mode, where the caller never has more than one app to ask about.
  def apps_for(branch)
    rule = promotion[branch.to_s]
    list = rule.is_a?(Hash) ? rule['apps'] : nil
    return nil unless list.is_a?(Array)

    names = list.map(&:to_s)
    names.empty? ? nil : names
  end

  # Whether admin-bypass merging (`gh pr merge --admin`, skipping the normal
  # review/CI wait) is permitted at all for a protected branch. Conservative
  # default is false: a repo must state in CHANGE.md that it allows the practice.
  # REDACTED, whose established flow admin-merges routinely once CI is green, sets
  # this true with `require_change_pass: true` so the audit gate still applies.
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
end
