# frozen_string_literal: true

require "minitest/autorun"
require_relative "home_fixture"
require_relative "../scripts/cf_secret_store"

# Every test process runs with a throwaway HOME, so the secret store a test
# touches is never the machine's real one.
class HomeFixtureTest < Minitest::Test
  def test_home_and_the_secret_store_are_not_the_real_ones
    refute_equal HomeFixture::REAL_HOME, ENV.fetch("HOME")
    assert_equal HomeFixture::HOME, ENV.fetch("HOME")
    refute CfSecretStore.root.start_with?(File.join(HomeFixture::REAL_HOME, ".claude")), CfSecretStore.root
  end
end
