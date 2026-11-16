# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../scripts/tracker_policy"
require_relative "../scripts/execution_config_schema"
require_relative "../scripts/change_policy"

class TrackerPolicyTest < Minitest::Test
  # The synthetic external-flow fixture's frontmatter (spec 0.19.0), as the
  # acceptance fixture carries it: a tracker policy plus its wiring.
  FIXTURE = YAML.safe_load(<<~YAML)
    change_config:
      execution:
        ledger_dir: plan
        adapters:
          cloud_agent:
            kind: github_issue
            repo: acme/widgets
            trigger_label: ready-for-agent
            bot_login: helper-bot[bot]
            design_ref: true
            ask_markers: ["Decision needed"]
            failure_markers: ["cannot access", "failed during", "Retry?"]
      outbound:
        spend_usd_cap: 2.0
        hold_flush_minutes: 15
        stale_hold_hours: 24
        roast_target: 9
        roast_rounds: 4
        templates: [tracker_link@1, issue_link@1, pr_link@1]
        channels:
          github: { deliver: send }
          jira: { deliver: send, tracker: jira }
      trackers:
        jira: { kind: jira, site: example.atlassian.net, provider: jira, project: PROJ }
    change_policy:
      trackers:
        jira:
          states: [Backlog, Ready to Pull, In Progress, Ready to Ship, Done]
          transitions:
            dispatch: { to: [Ready to Pull, In Progress] }
            merged: { comment: pr_link@1 }
            staging_passed: { to: [Ready to Ship], evidence: [deploy_run, check] }
            "release:production": { to: [Done] }
          evidence:
            deploy_run: { workflow: deploy-staging }
            check: { source: plan, name: check-import }
          handoffs:
            In Progress: builder
            Ready to Ship: releaser
          locks: { estimates: false, move_between_boards: false, rename: false }
  YAML

  def config = FIXTURE["change_config"]
  def policy = Marshal.load(Marshal.dump(FIXTURE.dig("change_policy", "trackers", "jira")))

  def errors_for(tracker_policy, cfg: config)
    TrackerPolicy.errors({ "jira" => tracker_policy }, config: cfg)
  end

  def test_fixture_policy_and_config_are_valid
    assert_empty errors_for(policy)
    assert_empty ExecutionConfigSchema.errors(config)
  end

  def test_absent_trackers_block_is_valid
    assert_empty TrackerPolicy.errors(nil)
  end

  def test_holder_must_be_a_role_never_a_person
    { "me" => /never a person/, "Me" => /never a person/, "dev@example.com" => /email/,
      "5b10ac8d82e05b22cc7d4ef5" => /account id/, "712020:1a2b" => /account id/,
      "Builder Person" => /role name/ }.each do |holder, message|
      p = policy
      p["handoffs"]["In Progress"] = holder
      assert_match message, errors_for(p).join("\n"), holder
    end
  end

  def test_handoff_state_must_exist
    p = policy
    p["handoffs"]["Review"] = "reviewer"
    assert_match(/state 'Review', which is not in/, errors_for(p).join)
  end

  def test_locks_are_schema_fixed_false
    TrackerPolicy::LOCKS.each do |lock|
      p = policy
      p["locks"][lock] = true
      assert_match(/locks\.#{lock} is schema-fixed false/, errors_for(p).join, lock)
    end
    p = policy
    p["locks"]["worklogs"] = false
    assert_match(/unknown key\(s\): worklogs/, errors_for(p).join)
  end

  def test_events_are_the_fixed_vocabulary
    p = policy
    p["transitions"]["deployed"] = { "to" => [ "Done" ] }
    assert_match(/'deployed' is not a cf event/, errors_for(p).join)
    p = policy
    p["transitions"]["release:staging"] = { "to" => [ "Done" ] }
    assert_empty errors_for(p)
  end

  def test_to_states_must_exist
    p = policy
    p["transitions"]["dispatch"] = { "to" => [ "Ready to Pull", "Doing" ] }
    assert_match(/names state 'Doing'/, errors_for(p).join)
    p["transitions"]["dispatch"] = { "to" => [] }
    assert_match(/non-empty ordered list/, errors_for(p).join)
  end

  def test_transition_needs_a_known_key
    p = policy
    p["transitions"]["asked"] = {}
    assert_match(/at least one of to, comment, evidence/, errors_for(p).join)
    p["transitions"]["asked"] = { "assign" => "builder" }
    assert_match(/unknown key\(s\): assign/, errors_for(p).join)
  end

  def test_comment_template_must_be_enabled_in_outbound
    p = policy
    p["transitions"]["pr_opened"] = { "comment" => "status_note@1" }
    assert_match(/status_note@1', which change_config.outbound.templates does not enable/, errors_for(p).join)
    assert_empty errors_for(p, cfg: nil)
    p["transitions"]["pr_opened"] = { "comment" => "free text here" }
    assert_match(/template name@version/, errors_for(p, cfg: nil).join)
  end

  def test_evidence_types_and_definitions
    p = policy
    p["transitions"]["staging_passed"]["evidence"] = [ "screenshot" ]
    assert_match(/'screenshot' is not an evidence type/, errors_for(p).join)
    p = policy
    p["evidence"].delete("check")
    assert_match(/needs 'check', which .* does not define/, errors_for(p).join)
  end

  def test_check_sources_are_typed
    examples = {
      { "source" => "command", "argv" => %w[bin/smoke --env staging], "cwd" => "repo", "timeout_s" => 600 } => nil,
      { "source" => "plan", "name" => "check-import" } => nil,
      { "source" => "manual", "prompt" => "Feature flag renders on staging" } => nil,
      { "source" => "command", "argv" => "bin/smoke --env staging", "cwd" => "repo", "timeout_s" => 600 } => /argv array, never a shell string/,
      { "source" => "command", "argv" => %w[bin/smoke], "cwd" => "/tmp", "timeout_s" => 600 } => /cwd must be one of repo/,
      { "source" => "command", "argv" => %w[bin/smoke] } => /cwd is required/,
      { "source" => "plan", "name" => "x", "argv" => %w[a] } => /unknown key\(s\): argv/,
      { "source" => "manual" } => /prompt is required/,
      { "source" => "ci" } => /source must be one of command, plan, manual/
    }
    examples.each do |check, message|
      p = policy
      p["evidence"]["check"] = check
      errors = errors_for(p)
      message ? assert_match(message, errors.join, check.inspect) : assert_empty(errors, check.inspect)
    end
  end

  def test_deploy_run_needs_a_workflow
    p = policy
    p["evidence"]["deploy_run"] = {}
    assert_match(/deploy_run.workflow must name/, errors_for(p).join)
  end

  def test_states_are_a_unique_non_empty_list
    p = policy
    p["states"] = []
    assert_match(/states must be a non-empty list/, errors_for(p).join)
    p["states"] = %w[A B A]
    assert_match(/lists A more than once/, errors_for(p).join)
  end

  def test_policy_needs_matching_wiring
    errors = TrackerPolicy.errors({ "linear" => policy }, config: config)
    assert_match(/no matching change_config.trackers.linear/, errors.join)
  end

  def test_unknown_policy_key
    p = policy
    p["estimates"] = { "points" => 3 }
    assert_match(/unknown key\(s\): estimates/, errors_for(p).join)
  end

  def test_roles_override_from_plan
    tracker = TrackerPolicy.new("jira", policy)
    assert_empty tracker.roles_override_errors({ "In Progress" => "reviewer" })
    assert_match(/state 'Review'/, tracker.roles_override_errors({ "Review" => "reviewer" }).join)
    assert_match(/never a person/, tracker.roles_override_errors({ "In Progress" => "me" }).join)
  end

  def test_change_policy_reports_tracker_errors
    p = policy
    p["handoffs"]["Done"] = "me"
    change_policy = ChangePolicy.new({ "trackers" => { "jira" => p } }, "CHANGE.md")
    assert_match(/never a person/, change_policy.tracker_errors(config: config).join)
    assert_empty ChangePolicy.new({}, "CHANGE.md").tracker_errors
  end
end
