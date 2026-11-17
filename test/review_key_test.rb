# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/review_key"
require_relative "../scripts/hook_event"

class ReviewKeyTest < Minitest::Test
  include SkillTempHome

  def setup
    super
    @root = File.realpath(Dir.mktmpdir)
    GitFixture.git_init(@root)
  end

  def teardown
    FileUtils.remove_entry(@root)
    super
  end

  def agent_tree(slug)
    dir = File.join(@root, ".claude", "worktrees", slug)
    FileUtils.mkdir_p(dir)
    GitFixture.git_init(dir)
    dir
  end

  def test_agent_id_wins
    event = { "session_id" => "s1", "agent_id" => "a9", "cwd" => agent_tree("agent-b") }
    assert_equal "s1:a9", ReviewKey.for(event)
  end

  def test_worktree_root_is_the_fallback_without_agent_id
    path = File.join(agent_tree("agent-b"), "x.rb")
    assert_equal "s1@agent-b", ReviewKey.for({ "session_id" => "s1" }, path: path)
    assert_equal "s1@agent-b", ReviewKey.for({ "session_id" => "s1", "cwd" => File.dirname(path) })
  end

  def test_coordinator_tree_keeps_the_bare_session
    assert_equal "s1", ReviewKey.for({ "session_id" => "s1" }, path: File.join(@root, "x.rb"))
    assert_equal "s1", ReviewKey.for({ "session_id" => "s1" })
  end

  def test_blank_session_stays_blank
    assert_equal "", ReviewKey.for({ "agent_id" => "a9" })
  end

  def test_dir_name_sanitizes_and_queue_uses_it
    assert_equal "s1_a9", ReviewKey.dir_name("s1:a9")
    ReviewQueue.new("s1:a9").add("ruby", "/p/x.rb", "h1")
    assert File.directory?(File.join(Dir.home, ".claude", "cf", "sessions", "s1_a9"))
  end

  def test_keys_for_session_lists_own_agent_and_worktree_keys_only
    %w[s1 s1:a9 s1@agent-b s10 s2].each { |key| ReviewQueue.new(key).add("ruby", "/p/x.rb", "h1") }
    assert_equal %w[s1 s1@agent-b s1_a9], ReviewKey.keys_for_session("s1")
  end

  def test_debug_keys_logs_key_names_never_values
    log = File.join(Dir.home, ".claude", "cf", "logs", "hook-keys.log")
    event = { "session_id" => "secret-value", "hook_event_name" => "Stop", "agent_id" => "a9" }
    HookEvent.debug_keys(event, "skill_review")
    refute File.exist?(log), "off unless the env flag is set"
    ENV["CF_HOOK_DEBUG_KEYS"] = "1"
    HookEvent.debug_keys(event, "skill_review")
    line = File.read(log)
    assert_includes line, "agent_id,hook_event_name,session_id"
    assert_includes line, "agent_id present: true"
    refute_includes line, "secret-value"
  ensure
    ENV.delete("CF_HOOK_DEBUG_KEYS")
  end
end
