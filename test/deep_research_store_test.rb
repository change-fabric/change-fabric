# frozen_string_literal: true

require_relative "deep_research_helper"

class DeepResearchStoreTest < Minitest::Test
  include DeepResearchHelper

  def test_layout_lives_under_the_research_root_and_never_overwrites
    dir = DeepResearchStore.create(record, "prompt text")
    assert_equal File.join(ENV["CF_RESEARCH_ROOT"], "synthetic", RUN_ID), dir
    assert_equal "prompt text", File.read(File.join(dir, "prompt.md"))
    assert_raises(DeepResearchStore::Error) { DeepResearchStore.create(record, "again") }
    assert_equal "prompt text", File.read(File.join(dir, "prompt.md"))
  end

  def test_state_transitions_follow_the_machine
    dir = DeepResearchStore.create(record, "p")
    assert_equal "ingested", DeepResearchStore.transition(dir, "ingested", "pdf_sha256" => "abc")["state"]
    assert_equal "abc", DeepResearchStore.read(dir)["pdf_sha256"]
    assert_equal "done", DeepResearchStore.transition(dir, "done")["state"]
    assert_raises(DeepResearchStore::Error) { DeepResearchStore.transition(dir, "pending") }
  end

  def test_pending_cannot_jump_to_done
    dir = DeepResearchStore.create(record, "p")
    assert_raises(DeepResearchStore::Error) { DeepResearchStore.transition(dir, "done") }
  end

  def test_writes_leave_no_temp_file
    dir = DeepResearchStore.create(record, "p")
    DeepResearchStore.transition(dir, "failed")
    assert_empty Dir.glob(File.join(dir, "*.tmp-*"))
  end

  def test_cache_hit_within_max_age_and_miss_past_it
    dir = DeepResearchStore.create(record("cache_key" => "k1"), "p")
    DeepResearchStore.transition(dir, "ingested")
    DeepResearchStore.transition(dir, "done")
    now = Time.utc(2026, 12, 1)
    assert_nil DeepResearchStore.cached("k1", now: now), "no report.json yet"
    File.write(DeepResearchStore.report_path(dir), "{}")
    assert_equal DeepResearchStore.report_path(dir), DeepResearchStore.cached("k1", now: now)
    assert_nil DeepResearchStore.cached("k1", now: Time.utc(2026, 12, 25)), "older than 30 days"
    assert_nil DeepResearchStore.cached("other", now: now)
  end

  def test_pending_runs_never_hit_the_cache
    DeepResearchStore.create(record("cache_key" => "k1"), "p")
    assert_nil DeepResearchStore.cached("k1", now: Time.utc(2026, 11, 21))
  end

  def test_slug_for
    assert_equal "explainers-prior-art", DeepResearchStore.slug_for("Explainers: prior art!")
    assert_equal "research", DeepResearchStore.slug_for("???")
    refute DeepResearchStore.valid_slug?("../x")
  end
end
