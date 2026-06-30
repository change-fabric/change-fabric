# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_retention"

class CtxRetentionTest < Minitest::Test
  include SkillTempHome

  NOOP = ->(_message) { }
  NOW = Time.new(2026, 6, 27, 12, 0, 0, "-04:00")

  # Under @home (the redirected HOME), so the store-keying guard accepts it.
  def cwd = File.join(@home, "code", "demo")

  def store(now: nil)
    CtxStore.new(cwd: cwd, home: @home, session_id: "s", device: "dev", committer: NOOP, now: now)
  end

  def write(now:, **fields)
    store(now: now).write(**fields)
  end

  def retention(now: NOW, caps: {})
    CtxRetention.new(store: store, now: now, caps: caps)
  end

  def write_raw(klass, name, extra_front)
    dir = CtxPaths.class_dir(klass, cwd, home: @home)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), "---\nname: #{name}\ndescription: x\n#{extra_front}\n---\n\nbody\n")
  end

  def test_truth_is_never_auto_removable_even_when_ancient
    ancient = Time.new(2020, 1, 1, 12, 0, 0, "-04:00")
    write(now: ancient, name: "msa", description: "c", klass: "truth", body: "x")
    assert_empty retention.auto_removable.select { |candidate| candidate.name == "msa" }
  end

  def test_fresh_truth_is_not_a_candidate
    write(now: NOW, name: "msa", description: "c", klass: "truth", body: "x")
    refute_includes retention.candidates.map(&:name), "msa"
  end

  def test_truth_past_review_horizon_is_flagged_for_review_not_removal
    old = Time.new(2025, 1, 1, 12, 0, 0, "-04:00")
    write(now: old, name: "msa", description: "c", klass: "truth", body: "x")

    msa = retention.needs_review.find { |candidate| candidate.name == "msa" }
    refute_nil msa, "stale truth should be flagged for review"
    assert_equal :review, msa.action
    assert_equal "review-due", msa.reason
    assert_empty retention.auto_removable, "review-due truth must never be auto-removable"
  end

  def test_per_doc_review_after_overrides_the_default_horizon
    touched = Time.new(2026, 4, 28, 12, 0, 0, "-04:00") # about 60 days before NOW
    write(now: touched, name: "short", description: "c", klass: "truth", review_after: "30d", body: "x")
    write(now: touched, name: "long", description: "c", klass: "truth", review_after: "999d", body: "x")

    due = retention.needs_review.select { |candidate| candidate.reason == "review-due" }.map(&:name)
    assert_includes due, "short"
    refute_includes due, "long"
  end

  def test_expired_ephemeral_is_auto_removable
    old = Time.new(2026, 6, 1, 12, 0, 0, "-04:00")
    write(now: old, name: "scratch", description: "s", klass: "ephemeral", ttl: "1d", body: "x")
    write(now: NOW, name: "fresh", description: "f", klass: "ephemeral", ttl: "30d", body: "x")

    auto = retention.auto_removable
    assert_equal %w[scratch], auto.map(&:name)
    assert_equal :remove, auto.first.action
  end

  def test_done_and_superseded_active_are_archive_candidates
    write(now: NOW, name: "d", description: "d", klass: "active", status: "done", body: "x")
    write(now: NOW, name: "s", description: "s", klass: "active", status: "superseded", body: "x")
    write(now: NOW, name: "live", description: "l", klass: "active", body: "x")

    review = retention.needs_review
    assert_equal %w[d s], review.select { |c| c.action == :archive }.map(&:name).sort
    refute_includes review.map(&:name), "live"
  end

  def test_stale_active_is_flagged_for_review
    oldish = Time.new(2026, 1, 1, 12, 0, 0, "-04:00")
    write(now: oldish, name: "dusty", description: "d", klass: "active", body: "x")
    write(now: NOW, name: "fresh", description: "f", klass: "active", body: "x")

    review = retention(caps: { stale_after_days: 30 }).needs_review
    assert_equal %w[dusty], review.select { |c| c.reason == "stale" }.map(&:name)
  end

  def test_over_cap_flags_the_oldest_active
    { "a" => 1, "b" => 2, "c" => 3, "d" => 4 }.each do |name, day|
      write(now: Time.new(2026, 6, day, 12, 0, 0, "-04:00"), name: name, description: name, klass: "active", body: "x")
    end

    review = retention(caps: { max_active: 2 }).needs_review
    assert_equal %w[a b], review.select { |c| c.reason == "over-cap" }.map(&:name).sort
  end

  def test_cli_prune_auto_removes_expired_and_reports_the_rest
    old = Time.new(2026, 6, 1, 12, 0, 0, "-04:00")
    write(now: old, name: "scratch", description: "s", klass: "ephemeral", ttl: "1d", body: "x")
    write(now: NOW, name: "done-plan", description: "d", klass: "active", status: "done", body: "x")
    write(now: NOW, name: "msa", description: "c", klass: "truth", body: "x")

    out = StringIO.new
    CtxRetention::CLI.prune(out: out, store: store)
    report = out.string

    assert_nil store.read("scratch"), "expired ephemeral should be auto-removed"
    assert_includes report, "auto-removed (expired ephemeral): scratch"
    assert_includes report, "archive done active/done-plan"
    refute_includes report, "msa"
  end

  def test_issues_flag_class_mismatch_and_bad_status
    write_raw("active", "wrongclass", "class: truth\nstatus: active")
    write_raw("active", "badstatus", "class: active\nstatus: bogus")
    write(now: NOW, name: "ok", description: "fine", klass: "active", body: "x")

    problems = retention.issues.map { |issue| [ issue.name, issue.problem ] }
    assert(problems.any? { |name, problem| name == "wrongclass" && problem.include?("does not match") })
    assert(problems.any? { |name, problem| name == "badstatus" && problem.include?("invalid status") })
    refute_includes retention.issues.map(&:name), "ok"
  end
end
