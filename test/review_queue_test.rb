# frozen_string_literal: true

require_relative "test_helpers"

class ReviewQueueTest < Minitest::Test
  include SkillTempHome

  def test_ack_records_verdict_and_clears_the_queue
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("ruby", "/p/b.rb", "h1")
    assert_equal %w[/p/a.rb /p/b.rb], queue.pending.map { |e| e[:path] }
    assert_equal %w[/p/a.rb /p/b.rb], queue.ack.map { |e| e[:path] }
    assert_empty ReviewQueue.new("s1").pending, "ack clears the queue"
  end

  def test_pending_does_not_clear_the_queue
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.pending
    refute_empty ReviewQueue.new("s1").pending, "reading pending must not drain"
  end

  def test_same_file_under_different_skills_keeps_both
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("refactoring", "/p/a.rb", "h1")
    assert_equal %w[refactoring ruby], queue.pending.map { |e| e[:skill] }.sort
  end

  def test_dedupes_by_skill_and_path_keeping_latest_hash
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.add("ruby", "/p/a.rb", "h2")
    rows = queue.pending
    assert_equal 1, rows.size
    assert_equal "h2", rows.first[:hash]
  end

  def test_acked_content_does_not_requeue_until_it_changes
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.ack
    queue.add("ruby", "/p/a.rb", "h1")
    assert_empty queue.pending, "same content stays reviewed"
    queue.add("ruby", "/p/a.rb", "h2")
    assert_equal [ "h2" ], queue.pending.map { |e| e[:hash] }
  end

  def test_reviewed_state_is_per_skill
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    queue.ack
    queue.add("refactoring", "/p/a.rb", "h1")
    assert_equal [ "refactoring" ], queue.pending.map { |e| e[:skill] }
  end

  def test_round_cap_trips_after_cap_rounds
    queue = ReviewQueue.new("s1")
    refute queue.capped?
    ReviewQueue::CAP.times { queue.bump_round }
    assert queue.capped?
  end

  def test_ack_resets_the_round_counter
    queue = ReviewQueue.new("s1")
    queue.add("ruby", "/p/a.rb", "h1")
    ReviewQueue::CAP.times { queue.bump_round }
    assert queue.capped?
    queue.ack
    assert_equal 0, ReviewQueue.new("s1").rounds, "a completed review resets the cap"
    refute ReviewQueue.new("s1").capped?
  end

  def test_blank_session_stays_empty
    queue = ReviewQueue.new("")
    queue.add("ruby", "/p/a.rb", "h1")
    assert_empty queue.pending
  end
end
