# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/roast"
require_relative "../scripts/roast_followups"

class RoastP1PassTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SECTION = "Open P1s at the stop"
  # A new caller must be added here on purpose.
  CALLERS = %w[
    skills/roast/SKILL.md skills/plan/SKILL.md skills/design/SKILL.md skills/walkthrough/SKILL.md
    skills/prototype/SKILL.md skills/drive/SKILL.md skills/brainstorm/SKILL.md
    skills/change/reference/CHANGE-frontmatter-spec.md
  ].freeze

  def test_every_caller_points_at_the_pass_and_the_followups_key
    CALLERS.each do |rel|
      text = File.read(File.join(ROOT, rel))
      assert_includes text, SECTION, "#{rel} names the pass section"
      assert_match(/followups/, text, "#{rel} names the followups key")
    end
  end

  def test_roast_skill_uses_role_tokens_and_no_tier_names
    text = File.read(File.join(ROOT, "skills/roast/SKILL.md"))
    %w[worker critic classifier].each { |r| assert_includes text, "{{model:#{r}}}" }
    refute_match(/\b(opus|sonnet|haiku)\b/i, text)
  end

  # Recording stub callables; `calls` is the shared ordered log.
  class Rig
    attr_reader :calls

    def initialize(needs_human: false, approved: true, verdicts: [ :resolved ], away: false)
      @calls = []
      @needs_human = needs_human
      @approved = approved
      @verdicts = verdicts.dup
      @away = away
    end

    def pass
      RoastFollowups::Pass.new(
        classify: ->(e) { @calls << [ :classify, e["id"] ]; { needs_human: @needs_human, reason: "taste call" } },
        ask: ->(e, _r) { @calls << [ :ask, e["id"] ]; { approved: @approved, direction: "go left" } },
        mitigate: ->(e, d) { @calls << [ :mitigate, e["id"], d ]; "fixed" },
        judge: ->(e) { @calls << [ :judge, e["id"] ]; @verdicts.shift || :unresolved },
        away: @away
      )
    end

    def names = @calls.map(&:first)
  end

  def run_pass(rig)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "round-1.response.json")
      issue = { "priority" => "P1", "where" => "hero", "problem" => "low contrast", "fix" => "darken" }
      RoastFollowups.upsert(path, RoastFollowups.from_critic(1, { "issues" => [ issue ] }))
      roast_calls = []
      original = Roast::Cli.method(:run)
      Roast::Cli.define_singleton_method(:run) { |*args, **_| roast_calls << args }
      begin
        rig.pass.run(path)
      ensure
        Roast::Cli.define_singleton_method(:run, original)
      end
      assert_empty roast_calls, "the pass never starts a roast round"
      RoastFollowups.followups(path).first
    end
  end

  def test_classify_runs_before_mitigate
    rig = Rig.new
    run_pass(rig)
    assert_equal :classify, rig.names.first
    assert_operator rig.names.index(:classify), :<, rig.names.index(:mitigate)
  end

  def test_away_mode_escalates_without_asking_or_fixing
    rig = Rig.new(needs_human: true, away: true)
    entry = run_pass(rig)
    assert_equal "escalated", entry["outcome"]
    assert_equal 0, entry["attempts"]
    assert_equal "taste call", entry["escalation_reason"]
    assert_equal [ :classify ], rig.names
  end

  def test_human_approves_then_fix_is_judged
    rig = Rig.new(needs_human: true, verdicts: [ :resolved ])
    entry = run_pass(rig)
    assert_equal "mitigated", entry["outcome"]
    assert_equal %i[classify ask mitigate judge], rig.names
    assert_equal "go left", rig.calls.find { |c| c[0] == :mitigate }[2]
  end

  def test_human_approves_but_fix_stays_unresolved_after_one_retry
    rig = Rig.new(needs_human: true, verdicts: %i[unresolved unresolved])
    entry = run_pass(rig)
    assert_equal "unresolved", entry["outcome"]
    assert_equal 2, entry["attempts"]
    assert_equal 2, rig.names.count(:mitigate)
  end

  def test_human_declines_and_nothing_is_fixed
    rig = Rig.new(needs_human: true, approved: false)
    entry = run_pass(rig)
    assert_equal "declined_by_human", entry["outcome"]
    assert_equal 0, entry["attempts"]
    refute_includes rig.names, :mitigate
  end

  def test_no_human_needed_resolves_first_try
    rig = Rig.new(verdicts: [ :resolved ])
    entry = run_pass(rig)
    assert_equal "mitigated", entry["outcome"]
    assert_equal 1, entry["attempts"]
    assert_equal "resolved", entry["judge_verdict"]
    refute_includes rig.names, :ask
  end

  def test_no_human_needed_unresolved_twice
    rig = Rig.new(verdicts: %i[unresolved unresolved])
    entry = run_pass(rig)
    assert_equal "unresolved", entry["outcome"]
    assert_equal 2, entry["attempts"]
  end

  def test_retry_succeeds_on_second_attempt
    entry = run_pass(Rig.new(verdicts: %i[unresolved resolved]))
    assert_equal "mitigated", entry["outcome"]
    assert_equal 2, entry["attempts"]
  end

  def test_a_fix_that_raises_a_new_decision_is_classified_again
    calls = []
    verdicts = [ { needs_human: false, reason: "" }, { needs_human: true, reason: "scope" } ]
    pass = RoastFollowups::Pass.new(
      classify: ->(_e) { calls << :classify; verdicts.shift },
      ask: ->(_e, _r) { calls << :ask; { approved: false, direction: "" } },
      mitigate: ->(_e, _d) { calls << :mitigate; { note: "x", decision: "rewrite the page?" } },
      judge: ->(_e) { calls << :judge; :resolved }
    )
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.json")
      RoastFollowups.upsert(path, RoastFollowups.from_critic(1, { "issues" => [ { "priority" => "P1", "where" => "a", "problem" => "b" } ] }))
      assert_equal "declined_by_human", pass.run(path).first["outcome"]
    end
    assert_equal %i[classify mitigate classify ask], calls
  end

  def test_settled_entries_are_not_rerun
    rig = Rig.new
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.json")
      RoastFollowups.upsert(path, RoastFollowups.from_critic(1, { "issues" => [ { "priority" => "P1", "where" => "a", "problem" => "b" } ] }))
      rig.pass.run(path)
      rig.pass.run(path)
    end
    assert_equal 1, rig.names.count(:mitigate)
  end

  def test_an_approved_decision_does_not_consume_the_retry
    asked = []
    notes = [ { note: "q", decision: "which palette?" }, "fixed", "fixed again" ]
    verdicts = %i[unresolved resolved]
    pass = RoastFollowups::Pass.new(
      classify: ->(e) { { needs_human: e["problem"] == "which palette?", reason: "taste" } },
      ask: ->(_e, _r) { asked << 1; { approved: true, direction: "blue" } },
      mitigate: ->(_e, _d) { notes.shift },
      judge: ->(_e) { verdicts.shift }
    )
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.json")
      RoastFollowups.upsert(path, RoastFollowups.from_critic(1, { "issues" => [ { "priority" => "P1", "where" => "a", "problem" => "b" } ] }))
      entry = pass.run(path).first
      assert_equal "mitigated", entry["outcome"]
      assert_equal 2, entry["attempts"]
    end
    assert_equal 1, asked.size
  end

  def test_a_worker_that_keeps_raising_decisions_ends_unresolved
    pass = RoastFollowups::Pass.new(
      classify: ->(_e) { { needs_human: false, reason: "" } },
      ask: ->(_e, _r) { { approved: true, direction: "" } },
      mitigate: ->(_e, _d) { { note: "q", decision: "again?" } },
      judge: ->(_e) { raise "never judged" }
    )
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.json")
      RoastFollowups.upsert(path, RoastFollowups.from_critic(1, { "issues" => [ { "priority" => "P1", "where" => "a", "problem" => "b" } ] }))
      assert_equal "unresolved", pass.run(path).first["outcome"]
    end
  end

  def test_brainstorm_materializes_followups_before_the_pass
    text = File.read(File.join(ROOT, "skills/brainstorm/SKILL.md"))
    assert_match(/roast\.rb decide --out-dir <plan_dir>\/roast --cap 1/, text)
  end

  def test_plan_materializes_followups_at_its_own_cap
    text = File.read(File.join(ROOT, "skills/plan/SKILL.md"))
    assert_match(/decide --out-dir <plan_dir>\/roast --cap <rounds completed>/, text)
  end
end
