#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_apps'
require_relative 'change_gate_store'
require_relative 'change_override_store'

# The one question both release gates ask, extracted so `change_merge_guard.rb`
# (gh pr merge into a protected branch) and `change_tag_guard.rb` (pushing a
# protected release tag) resolve "is there a passing record for this exact
# commit" identically. Everything upstream of this question differs by event
# (command surface, fact resolution, ref-to-rule matching, deny wording); only
# the final gate check is shared, so it lives here rather than in either hook.
class ChangeGateCheck
  def initialize(sha:, profile:, apps: nil)
    @sha = sha
    @profile = profile
    @apps = apps
  end

  # True when a human-recorded override covers this (sha, profile), or a
  # passing comprehensive cf:change run is on record, scoped to `apps` (0.4.0
  # monorepo mode) when given, or the unscoped 0.3.1 question otherwise.
  def satisfied?
    return true if ChangeOverrideStore.new(@sha, profile: @profile).authorized?

    store.comprehensive_pass?(apps: @apps)
  end

  # The subset of `apps` with no passing comprehensive entry recorded, or []
  # in single-app mode (where `apps` is nil and the question is unscoped).
  def missing_apps
    return [] unless @apps

    store.missing_apps(@apps)
  end

  # " for app(s): a, b", or '' in single-app mode. Named so a deny message can
  # be built without the caller re-deriving it from `missing_apps`.
  def missing_apps_clause
    return '' unless @apps

    " for app(s): #{missing_apps.join(', ')}"
  end

  # CLI flags (`--profile X --app a --app b`) a rerun would need to close the
  # gap this check found, or [] when nothing beyond a bare rerun is required.
  def flags
    flags = []
    flags << "--profile #{@profile}" if @profile
    flags << "--app #{missing_apps.join(' --app ')}" if @apps
    flags
  end

  def store
    @store ||= ChangeGateStore.new(@sha, profile: @profile)
  end

  # The app names (0.4.0) a passing gate record must cover for a promotion
  # rule, or nil in single-app mode (where `satisfied?` asks its original,
  # unscoped question). Registry read failures fail open (nil, meaning "do
  # not scope by app") rather than deny a promotion this check cannot
  # actually evaluate.
  def self.required_apps(root, apps_from_rule)
    registry = ChangeAppRegistry.load(File.join(root, 'CHANGE.md'))
    return nil unless registry.multi_app?

    apps_from_rule || registry.enabled_entries.map(&:name)
  rescue StandardError
    nil
  end

  # CF_ALLOW_UNGATED_MERGE=1 only works if it was exported before this
  # session's own hook process started, which an agent mid-session cannot
  # arrange. The reachable path: a human runs change_override.rb themselves,
  # from their own real terminal (it refuses without one), to record an
  # auditable, sha-scoped override this class's `satisfied?` checks. Shared by
  # both guards, deliberately: one escape hatch and one override script, not a
  # second name to get wrong for tags.
  def self.escape_note
    'Set CF_ALLOW_UNGATED_MERGE=1 before this session started, or, from your own terminal, ' \
      "record an override: ruby ~/.claude/cf/bin/change_override.rb <sha> --reason '<why>'."
  end
end
