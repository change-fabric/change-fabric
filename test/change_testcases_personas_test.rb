# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_testcases_personas"

# The per-persona login cache: one login per persona, and exactly one re-login
# however many cases see the same session expire at once.
class ChangeTestcasesPersonasTest < Minitest::Test
  def cache(delay: 0, &block)
    count = 0
    lock = Mutex.new
    PersonaCache.new do |name|
      sleep(delay) if delay.positive?
      next block.call(name) if block

      lock.synchronize do
        count += 1
        { "persona" => name, "n" => count }
      end
    end
  end

  def test_one_login_per_persona_however_many_cases_fetch_it
    personas = cache(delay: 0.01)
    threads = Array.new(8) { |i| Thread.new { personas.fetch(i.even? ? "admin" : "viewer") } }
    results = threads.map(&:value)
    assert_equal({ "admin" => 1, "viewer" => 1 }, personas.logins)
    assert(results.all? { |_state, generation| generation == 1 })
  end

  def test_concurrent_expiry_logs_in_exactly_once_and_everyone_reuses_it
    personas = cache(delay: 0.02)
    _state, generation = personas.fetch("admin")
    threads = Array.new(6) { Thread.new { personas.refresh("admin", generation) } }
    generations = threads.map { |thread| thread.value.last }
    assert_equal 2, personas.logins["admin"]
    assert_equal [ 2 ], generations.uniq
  end

  def test_a_stale_refresh_reuses_the_newer_state
    personas = cache
    personas.fetch("admin")
    personas.refresh("admin", 1)
    _state, generation = personas.refresh("admin", 1)
    assert_equal 2, generation
    assert_equal 2, personas.logins["admin"]
  end

  def test_a_failed_login_fails_every_caller_without_retrying
    personas = cache { |_name| raise PersonaCache::LoginError, "bad password" }
    2.times do
      error = assert_raises(PersonaCache::LoginError) { personas.fetch("admin") }
      assert_equal "bad password", error.message
    end
    assert_equal 1, personas.logins["admin"]
  end
end
