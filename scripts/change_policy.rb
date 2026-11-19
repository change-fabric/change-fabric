#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'open3'
require_relative 'change_frontmatter'
require_relative 'change_schema'
require_relative 'tracker_policy'

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
  # Raised by `for_ref` when the base ref's CHANGE.md cannot be determined at
  # all (the ref cannot be resolved, a fetch never ran, git itself fails) -
  # distinct from the ref resolving cleanly to "no CHANGE.md there" (nil,
  # ungoverned). A gating decision that cannot tell which of these is true
  # must not quietly fall back to the PR's own working-tree policy (#553), so
  # callers that gate on this are expected to fail closed on the exception
  # rather than rescue it into nil.
  class Unreadable < StandardError; end

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

  # Loads the policy from CHANGE.md as it stands at `ref` (e.g. `origin/main`,
  # a sha), never the working tree. This is what every gating decision must
  # read (#553): a PR cannot weaken the policy it is judged by just by editing
  # its own working-tree CHANGE.md, because that copy is never consulted here.
  #
  # Returns nil when `ref` resolves cleanly but has no CHANGE.md at all (an
  # ungoverned base, same meaning as `for_repo` returning nil). Raises
  # `Unreadable` when the ref or the read itself cannot be determined - an
  # unresolvable ref, a repo git cannot operate on, any git failure other than
  # "the path is absent in that tree" - so a gating caller can fail closed
  # instead of silently treating "could not check" as "nothing to enforce".
  # A malformed-but-present CHANGE.md at ref is not rescued here the way
  # `for_repo` rescues one on disk: the base ref is immutable from the PR's
  # vantage point, so there is no risk of an agent's bad edit wedging the
  # gate, and a caller is better served failing closed on it like any other
  # read it cannot trust.
  def self.for_ref(root, ref)
    commit = resolve_commit(root, ref)
    return nil unless change_md_in_tree?(root, commit)

    out, ok, err = git_show_change_md(root, commit)
    return parse_ref_policy(out, ref) if ok

    raise Unreadable, "cannot read CHANGE.md at #{ref} in #{root}: #{err.strip}"
  end

  # Fetches `branch` from `remote` (a remote name or URL) into `dest` and
  # returns `dest`, or nil when the fetch fails. Callers go through
  # ChangePolicy::Source, which picks the remote and names the ref; an explicit
  # destination refspec matters because a single-branch clone's fetch mapping
  # would not update <remote>/<branch>, so a remote-tracking ref read
  # afterwards could see nothing, or a stale copy.
  def self.fetch_into(root, remote, branch, dest)
    _out, status = Open3.capture2e('git', '-C', root.to_s, 'fetch', '--quiet', '--no-tags', remote.to_s,
                                   "+refs/heads/#{branch}:#{dest}")
    status.success? ? dest : nil
  rescue StandardError
    nil
  end

  # The commit sha `ref` names, or Unreadable when it does not resolve.
  def self.resolve_commit(root, ref)
    out, status = Open3.capture2e('git', '-C', root.to_s, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}")
    raise Unreadable, "cannot resolve #{ref} in #{root}: #{out.strip}" unless status.success?

    out.strip
  rescue SystemCallError => e
    raise Unreadable, "cannot resolve #{ref} in #{root}: #{e.message}"
  end

  # Tree membership, not a git diagnostic: whether CHANGE.md is absent from
  # the commit says nothing about the working tree (a PR adding CHANGE.md to
  # an ungoverned base must read as ungoverned).
  def self.change_md_in_tree?(root, commit)
    out, status = Open3.capture2e('git', '-C', root.to_s, 'ls-tree', '--name-only', commit, '--', 'CHANGE.md')
    raise Unreadable, "cannot list the tree of #{commit} in #{root}: #{out.strip}" unless status.success?

    out.lines.map(&:strip).include?('CHANGE.md')
  end

  # Any parse failure (Psych::DisallowedClass for an unquoted date,
  # Psych::AliasesNotEnabled, a syntax error) becomes Unreadable so gating
  # callers fail closed instead of a stray exception being swallowed.
  def self.parse_ref_policy(out, ref)
    new(ChangeFrontmatter.parse(out)['change_policy'], "#{ref}:CHANGE.md")
  rescue StandardError => e
    raise Unreadable, "cannot parse CHANGE.md at #{ref}: #{e.class}: #{e.message}"
  end

  def self.git_show_change_md(root, ref)
    out, status = Open3.capture2e('git', '-C', root.to_s, 'show', "#{ref}:CHANGE.md")
    [ out, status.success?, status.success? ? '' : out ]
  rescue StandardError => e
    [ '', false, e.message ]
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

  # protected_refs (0.9.0): the raw list, each entry an unprefixed
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

  # Whether a merge into this branch additionally requires the recorded
  # comprehensive pass to carry a passing `testcases` lane (0.10.0). Opt-in and
  # default false: a repo adopting the regression lane runs it for a while
  # before it is willing to have a merge blocked on it, and a lane the repo has
  # not enabled at all must not silently start gating. Once set, it is stricter
  # than `require_change_pass` alone, which only asks whether the run passed
  # overall and would be satisfied by a run that never ran the lane. Read off
  # `branch_promotion` for the same reason `require_change_pass?` is: a `tag:`
  # rule must never answer for a branch that happens to read the same.
  def require_testcases?(branch)
    rule = branch_promotion[branch.to_s]
    rule.is_a?(Hash) && rule['require_testcases'] == true
  end

  # The per-environment promotion rules block, unfiltered: every key exactly
  # as authored, branch and tag alike. Each value maps to that target's
  # answers: review_required, self_review_allowed, require_change_pass,
  # ci_gate, ci_skippable, profile, apps, environment, require_testcases, and
  # (tag rules only) require_trunk_ancestor/require_prior_tag. The prose body
  # is expected to expand each into a straight answer a teammate can be
  # pointed at.
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
    return gate_block['require_change_pass'] != false unless rule.is_a?(Hash)

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

  # Tag-rule-only fields (0.9.0), read as raw rule-hash accessors so
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
  # When the cf:change gate applies to a PR merge (0.14.0): 'every_merge' (the
  # default, also for an absent or invalid value, which ChangeSchema.gate_errors
  # reports) or 'promotion'.
  def gate_require_on
    value = gate_block['require_on'].to_s
    ChangeSchema::GATE_SCOPES.include?(value) ? value : 'every_merge'
  end

  # A PR merge into trunk is never a promotion.
  def gate_required_for_pr_merge?(base) = gate_require_on == 'every_merge' || !trunk?(base)

  def trunk?(branch) = branch.to_s == trunk_branch

  def trunk_branch
    value = gate_block['trunk']
    value.is_a?(String) && !value.strip.empty? ? value : 'main'
  end

  def gate_errors = ChangeSchema.gate_errors(@policy)

  # change_policy.trackers (0.19.0). config is the change_config block, for
  # the checks that span both (a policy's wiring, an enabled template).
  def tracker_errors(config: nil) = TrackerPolicy.errors(@policy['trackers'], config: config)

  # The gate mapping, or {} when absent or malformed (a scalar or list), so a
  # bad block falls back to the conservative defaults instead of raising.
  def gate_block
    gate = @policy['gate']
    gate.is_a?(Hash) ? gate : {}
  end

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

# The one answer to "whose CHANGE.md governs this action?" (#553). Every
# gating caller builds a Source from what it actually knows about the
# destination (a PR URL's host/owner/repo, or a `git push <repository>`
# argument) and fetches that repository's branch through it; no guard matches
# remotes on its own. A remote URL in any of its spellings (ssh://, https://,
# scp-style git@host:owner/repo, with or without .git) normalizes to the same
# host/owner/repo identity, so a GitHub Enterprise repo never matches a
# github.com remote that happens to share owner/repo.
class ChangePolicy
  class Source
    REF_ROOT = 'refs/cf/policy-base'

    attr_reader :remote, :identity

    # [host, owner, repo] (host and path lowercased, .git dropped) from a
    # remote or PR URL, or nil for anything else (a local path, a remote name).
    def self.parse_url(url)
      text = url.to_s.strip
      m = text.match(%r{\A(?:https?|ssh|git)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)\z}) ||
          text.match(%r{\A(?:[^@/\s]+@)?([^/:\s]+):(?!/)(.+)\z})
      return nil unless m

      parts = m[2].sub(%r{/pull/.*\z}, '').sub(%r{/+\z}, '').sub(/\.git\z/, '').split('/')
      return nil unless parts.size == 2 && parts.none?(&:empty?)

      [ m[1].downcase, *parts.map(&:downcase) ]
    end

    # The source for a known repository identity (from a PR URL): the
    # configured remote whose URL names the same host/owner/repo, else an https
    # URL on that same host.
    def self.for_identity(root, identity)
      host, owner, repo = identity
      match = remotes(root).find { |_name, url| parse_url(url) == identity }
      new(root, match ? match.first : "https://#{host}/#{owner}/#{repo}.git", identity)
    end

    # The source for a PR URL, or the default push destination when the URL
    # cannot be parsed.
    def self.for_pr_url(root, url)
      identity = parse_url(url)
      identity ? for_identity(root, identity) : resolve!(root, nil)
    end

    # The source a `git push <repository>` publishes to. `destination` is the
    # <repository> argument: a configured remote name, or a URL or path. nil
    # means git's own default: the current branch's push remote
    # (branch.<b>.pushRemote, remote.pushDefault, branch.<b>.remote), else
    # origin. Returns nil when the destination is neither a configured remote
    # nor a URL or existing path, so a caller fails closed on it.
    def self.for_destination(root, destination)
      configured = remotes(root)
      name = destination || default_push_remote(root)
      return push_source(root, name, configured[name]) if configured.key?(name)
      return nil if destination.nil?

      identity = parse_url(destination)
      return new(root, destination, identity) if identity || File.directory?(File.expand_path(destination, root))

      nil
    end

    # A remote publishes to its push URL (`git remote get-url --push`), which
    # differs from its fetch URL when a pushurl is set. Keep the remote name
    # (and its fetch identity) when they agree; otherwise read the policy from
    # the push repository, identified by the pushurl as written.
    # Several push URLs publish to several repositories; this resolver reads
    # one policy, so it returns nil and a governed caller fails closed.
    def self.push_source(root, name, url)
      pushes = git(root, 'remote', 'get-url', '--push', '--all', name).to_s.lines.map(&:strip).uniq
      return nil if pushes.size > 1

      push = pushes.first
      return new(root, name, parse_url(url)) unless split_push?(root, name)

      written = git(root, 'config', '--get', "remote.#{name}.pushurl") || push
      new(root, written, parse_url(written))
    end

    # True when the remote's push URL differs from its fetch URL.
    def self.split_push?(root, name)
      push = git(root, 'remote', 'get-url', '--push', name)
      !push.nil? && push != git(root, 'remote', 'get-url', name)
    end

    # for_destination, raising Unreadable instead of returning nil.
    def self.resolve!(root, destination)
      for_destination(root, destination) or
        raise Unreadable, "cannot resolve the repository '#{destination || 'default push remote'}' names"
    end

    def self.default_push_remote(root)
      branch = git(root, 'symbolic-ref', '--quiet', '--short', 'HEAD')
      keys = branch ? [ "branch.#{branch}.pushRemote", 'remote.pushDefault', "branch.#{branch}.remote" ] : []
      keys << 'remote.pushDefault' if keys.empty?
      keys.lazy.filter_map { |key| git(root, 'config', '--get', key) }.first || 'origin'
    end

    # The remote name `gh repo set-default` chose (remote.<name>.gh-resolved),
    # or nil when no gh default is configured.
    def self.gh_default_remote(root)
      out = git(root, 'config', '--get-regexp', '^remote\\..*\\.gh-resolved$') or return nil
      out.lines.first.split(' ', 2).first.delete_prefix('remote.').delete_suffix('.gh-resolved')
    end

    # { name => url } for every configured remote, as written in the config
    # (before any insteadOf rewrite), which is the identity the user named.
    def self.remotes(root)
      out = git(root, 'config', '--get-regexp', '^remote\\..*\\.url$') or return {}
      out.lines.each_with_object({}) do |line, acc|
        key, url = line.split(' ', 2)
        acc[key.delete_prefix('remote.').delete_suffix('.url')] = url.to_s.strip
      end
    end

    def self.git(root, *args)
      out, status = Open3.capture2e('git', '-C', root.to_s, *args)
      status.success? && !out.strip.empty? ? out.strip : nil
    rescue StandardError
      nil
    end

    def initialize(root, remote, identity)
      @root = root
      @remote = remote
      @identity = identity
    end

    # The destination repository's own default branch, asked of that
    # repository (ls-remote --symref), never of origin or CHANGE.md.
    def default_branch
      out = self.class.git(@root, 'ls-remote', '--symref', @remote, 'HEAD') or return nil
      out[%r{^ref: refs/heads/(\S+)\s+HEAD$}, 1]
    end

    # Fetches `branch` into refs/cf/policy-base/<host>/<owner>/<repo>/<branch>
    # (or local/<remote> when the destination has no URL identity) and returns
    # that ref, or nil when the fetch fails.
    def fetch(branch)
      ChangePolicy.fetch_into(@root, @remote, branch, "#{REF_ROOT}/#{ref_scope}/#{branch}")
    end

    # The policy at `branch` of this source: a ChangePolicy, nil (ungoverned
    # there), or Unreadable when the fetch or the read fails.
    def policy(branch)
      ref = fetch(branch) or raise Unreadable, "cannot fetch #{branch} from #{@remote}"

      ChangePolicy.for_ref(@root, ref)
    end

    private

    def ref_scope
      return @identity.join('/') if @identity

      "local/#{@remote.to_s.gsub(/[^A-Za-z0-9._-]+/, '_')}"
    end
  end
end
