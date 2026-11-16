# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/away_guard"
require_relative "../scripts/cf_runtime"

# Where a staged secret goes has no safe default, so away mode still asks.
class SecretIntakeAwayFloorTest < Minitest::Test
  def test_secret_destination_is_a_floor_header_in_both_lists
    assert_includes AwayGuard::FLOOR, "Secret destination"
    assert_includes CfRuntime::FLOOR, "Secret destination"
  end
end
