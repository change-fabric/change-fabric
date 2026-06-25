# frozen_string_literal: true

require_relative "test_helpers"

class ReviewAckTest < Minitest::Test
  include SkillTempHome

  SCRIPT = File.expand_path("../scripts/review_ack.rb", __dir__)

  def test_script_acks_the_session_queue
    ReviewQueue.new("s1").add("ruby", "/p/x.rb", "h1")
    out = `ruby #{SCRIPT} s1`
    assert_includes out, "Recorded 1 file(s)"
    assert_empty ReviewQueue.new("s1").pending, "queue cleared after ack"
    ReviewQueue.new("s1").add("ruby", "/p/x.rb", "h1")
    assert_empty ReviewQueue.new("s1").pending, "acked content does not re-queue"
  end

  def test_blank_session_is_a_noop
    out = `ruby #{SCRIPT}`
    assert_includes out, "Recorded 0 file(s)"
  end
end
