# frozen_string_literal: true

require_relative "test_helpers"
require "open3"
require_relative "../install"
require_relative "../scripts/hook_event"
require_relative "../scripts/review_stage1"

class InstallMatchersTest < Minitest::Test
  # The tools each deny guard's spec names (its own tool check, read from the
  # script). A matcher must cover all of them.
  DENY_TOOLS = {
    "secrets_read_guard" => %w[Bash Read Edit Write MultiEdit NotebookEdit Grep Glob],
    "force_push_guard" => %w[Bash],
    "client_name_guard" => %w[Bash Write Edit MultiEdit NotebookEdit mcp__slack__slack_send_message],
    "review_gate" => %w[Bash],
    "noreply_guard" => %w[Bash],
    "docker_doctrine_guard" => %w[Bash],
    "change_merge_guard" => %w[Bash],
    "change_tag_guard" => %w[Bash],
    "presence_probe" => %w[Edit Write NotebookEdit],
    "prod_approval_guard" => %w[Bash],
    "glyph_guard" => %w[Bash Write Edit]
  }.freeze

  def setup
    @home = Dir.mktmpdir
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
    capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
    @settings = JSON.parse(File.read(paths.settings))["hooks"]
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def groups_for(event, script)
    @settings.fetch(event).select { |g| g["hooks"].any? { |h| h["command"].end_with?("/#{script}.rb") } }
  end

  def covers?(matcher, tool) = Regexp.new("\\A(?:#{matcher})\\z").match?(tool)

  def test_every_pre_and_post_tool_use_entry_written_by_the_installer_has_a_matcher
    %w[PreToolUse PostToolUse].each do |event|
      Install::Installer::HOOKS.fetch(event).each do |script|
        groups = groups_for(event, script.sub(".rb", ""))
        assert_equal 1, groups.size, "#{script} should be wired once under #{event}"
        refute_nil groups.first["matcher"], "#{script} has no matcher"
        refute_empty groups.first["matcher"]
      end
    end
  end

  def test_each_deny_guards_matcher_covers_the_tools_its_spec_names
    DENY_TOOLS.each do |guard, tools|
      matcher = groups_for("PreToolUse", guard).first["matcher"]
      tools.each { |tool| assert covers?(matcher, tool), "#{guard} matcher #{matcher.inspect} misses #{tool}" }
    end
  end

  def test_the_table_covers_every_deny_rule_that_runs_on_tool_use
    deny_tool_hooks = HookEvent.rule_ids.values.select { |r| r["kind"] == "deny" && %w[PreToolUse PostToolUse].include?(r["event"]) }
                               .map { |r| r["hook"] }.uniq
    assert_equal deny_tool_hooks.sort, DENY_TOOLS.keys.sort
  end

  def test_a_matcher_never_hides_a_tool_the_script_checks_for
    DENY_TOOLS.each_key do |guard|
      source = File.read(File.expand_path("../scripts/#{guard}.rb", __dir__))
      named = source.scan(/tool_name'\] == '(\w+)'/).flatten
      matcher = groups_for("PreToolUse", guard).first["matcher"]
      named.each { |tool| assert covers?(matcher, tool), "#{guard} checks #{tool} but its matcher is #{matcher.inspect}" }
    end
  end

  def test_only_the_review_gate_carries_a_hook_timeout_for_its_stage_one_checks
    gate = groups_for("PreToolUse", "review_gate").first["hooks"].first
    assert_operator gate["timeout"], :>=, 3 * ReviewStage1::DEFAULT_TIMEOUT
    tool_hooks = @settings.values_at("PreToolUse", "PostToolUse").compact.flatten.flat_map { |group| group["hooks"] }
    others = tool_hooks.reject { |hook| hook["command"].end_with?("/review_gate.rb") || hook["command"].match?(/cf_host_hook|pulse_stamp/) }
    assert_empty others.select { |hook| hook.key?("timeout") }
  end

  def test_the_matcher_is_written_beside_the_command_and_survives_reinstall
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
    capture_io { Install::Installer.new(paths: paths, ruby: "/usr/bin/ruby").install }
    again = JSON.parse(File.read(paths.settings))["hooks"]
    assert_equal @settings["PreToolUse"].map { |g| g["matcher"] }, again["PreToolUse"].map { |g| g["matcher"] }
  end

  def test_rule_ids_are_installed_beside_both_script_copies
    paths = Install::Paths.new(repo: File.expand_path("..", __dir__), home: @home)
    [ paths.bin, paths.runtime_bin ].each do |bin|
      assert File.exist?(File.expand_path("../config/rule_ids.yml", bin)), "rule_ids.yml missing beside #{bin}"
    end
  end
end
