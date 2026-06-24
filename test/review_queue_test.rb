# frozen_string_literal: true

require_relative "test_helpers"

class ReviewQueueTest < Minitest::Test
  include SkillTempHome

  def test_drain_clears_the_queue
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("ruby", "/p/b.rb", "h1")
    assert_equal %w[/p/a.rb /p/b.rb], queue.drain.map { |e| e[:path] }
    assert_empty ReviewQueue.new("s1").drain
  end

  def test_same_file_under_different_skills_keeps_both
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("refactoring", "/p/a.rb", "h1")
    assert_equal %w[refactoring ruby], queue.drain.map { |e| e[:skill] }.sort
  end

  def test_dedupes_by_skill_and_path_keeping_latest_hash
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("ruby", "/p/a.rb", "h2")
    rows = queue.drain
    assert_equal 1, rows.size
    assert_equal "h2", rows.first[:hash]
  end

  def test_skips_content_already_reviewed_then_requeues_new_content
    queue = ReviewQueue.new("s1")
    queue.mark_reviewed([ { skill: "ruby", path: "/p/a.rb", hash: "h1" } ])
    queue.add("ruby", "/p/a.rb", "h1")
    assert_empty queue.drain, "same content must not re-queue"
    queue.add("ruby", "/p/a.rb", "h2")
    assert_equal [ "h2" ], queue.drain.map { |e| e[:hash] }
  end

  def test_reviewed_state_is_per_skill
    queue = ReviewQueue.new("s1")
    queue.mark_reviewed([ { skill: "ruby", path: "/p/a.rb", hash: "h1" } ])
    queue.add("refactoring", "/p/a.rb", "h1")
    assert_equal [ "refactoring" ], queue.drain.map { |e| e[:skill] }
  end

  def test_round_cap_trips_after_cap_rounds
    queue = ReviewQueue.new("s1")
    refute queue.capped?
    ReviewQueue::CAP.times { queue.bump_round }
    assert queue.capped?
  end

  def test_blank_session_stays_empty
    queue = ReviewQueue.new("")
    queue.add("ruby", "/p/a.rb", "h1")
    assert_empty queue.drain
  end
end
