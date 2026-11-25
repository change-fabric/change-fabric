# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../install"
require_relative "../scripts/hook_event"

class HookEventRecordTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def lines
    path = HookEvent.events_path(@home)
    File.file?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  def test_drops_every_content_field_and_unsafe_value
    HookEvent.record("evaluation", session: "s1", home: @home, rule_id: "force_push_guard/deny", rule_version: "ab12cd34",
                                   hook: "force_push_guard", tool: "Bash", command: "git push --force", prompt: "secret text",
                                   path: "/Users/someone/file.rb", diff: "+ a line")
    HookEvent.record("intervention", session: "s1", home: @home, rule_id: "x/deny", rule_version: "ab12cd34",
                                     outcome: "deny", reason: "denied because of this")
    allowed = HookEvent::COMMON_FIELDS + HookEvent::TYPE_FIELDS.values.flatten
    lines.each do |line|
      assert_empty line.keys.map(&:to_sym) - allowed
      line.each_value { |v| refute_match(/\s/, v.to_s) }
    end
    refute_includes File.read(HookEvent.events_path(@home)), "git push"
  end

  def test_nil_home_falls_back_to_dir_home_for_doctrine_version
    dir = File.join(@home, ".claude", "cf", "sessions", "s9")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "doctrine-version"), "v7\n")
    real = ENV.fetch("HOME", nil)
    ENV["HOME"] = @home
    assert_equal "v7", HookEvent.doctrine_version("s9", home: nil)
    assert_equal "v7", HookEvent.record("rubric_surfaced", session: "s9", rule_id: "r", rule_version: "ab12cd34")[:doctrine_version]
  ensure
    ENV["HOME"] = real
  end

  def test_a_value_with_spaces_or_slashes_in_free_text_is_dropped
    HookEvent.record("evaluation", session: "s1", home: @home, rule_id: "a/b", tool: "rm -rf /tmp/x")
    assert_nil lines.first["tool"]
  end

  def test_unknown_type_and_bad_outcome_write_nothing
    assert_nil HookEvent.record("prompt", session: "s1", home: @home, text: "hi")
    assert_nil HookEvent.record("intervention", session: "s1", home: @home, rule_id: "a/b", outcome: "explode")
    assert_empty lines
  end

  def test_evaluation_without_intervention_when_the_hook_stays_silent
    HookEvent.instrument("force_push_guard", { "session_id" => "s1", "tool_name" => "Bash" }, home: @home) { nil }
    assert_equal %w[evaluation], lines.map { |l| l["type"] }
    assert_equal "force_push_guard/deny", lines.first["rule_id"]
    assert_equal "Bash", lines.first["tool"]
  end

  def test_a_denial_records_evaluation_and_a_separate_intervention
    deny = { hookSpecificOutput: { permissionDecision: "deny", permissionDecisionReason: "no" } }
    out = capture_io { HookEvent.instrument("force_push_guard", { "session_id" => "s1" }, home: @home) { puts JSON.generate(deny) } }.first
    assert_equal JSON.generate(deny), out.strip, "the hook's output must pass through untouched"
    assert_equal %w[evaluation intervention], lines.map { |l| l["type"] }
    assert_equal "deny", lines.last["outcome"]
  end

  def test_an_advisory_context_is_advise_and_an_injector_is_inject
    ctx = JSON.generate(hookSpecificOutput: { additionalContext: "x" })
    capture_io { HookEvent.instrument("slop_remind", { "session_id" => "s1" }, home: @home) { puts ctx } }
    capture_io { HookEvent.instrument("skill_detect", { "session_id" => "s1" }, home: @home) { puts ctx } }
    assert_equal %w[advise inject], lines.select { |l| l["type"] == "intervention" }.map { |l| l["outcome"] }
  end

  def test_session_start_once_and_session_end_with_turns
    digest = JSON.generate(hookSpecificOutput: { additionalContext: "digest text" })
    event = { "session_id" => "s1", "model" => "claude-sonnet-5-5" }
    2.times { capture_io { HookEvent.instrument("doctrine_digest", event, home: @home) { puts digest } } }
    2.times { HookEvent.instrument("key_paste_guard", event, home: @home) { nil } }
    HookEvent.instrument("inbox_session_end", event, home: @home) { nil }
    HookEvent.instrument("telemetry_emit", event, home: @home) { nil }
    starts = lines.select { |l| l["type"] == "session_start" }
    ends = lines.select { |l| l["type"] == "session_end" }
    assert_equal 1, starts.size
    assert_equal "sonnet", starts.first["model_tier"]
    assert_equal HookEvent.sha8("digest text"), starts.first["doctrine_version"]
    assert_equal [ 2 ], ends.map { |l| l["turns"] }
  end

  def test_a_hook_that_raises_still_passes_output_and_records
    assert_raises(RuntimeError) do
      capture_io { HookEvent.instrument("slop_remind", { "session_id" => "s1" }, home: @home) { raise "boom" } }
    end
    assert_equal %w[evaluation], lines.map { |l| l["type"] }
  end

  def test_an_unwritable_log_never_raises
    File.write(File.join(@home, ".claude"), "a file where a directory should be")
    assert_nil HookEvent.record("evaluation", session: "s1", home: @home, rule_id: "a/b")
  end

  def test_every_hook_in_the_installer_has_a_declared_rule
    require_relative "../install"
    declared = HookEvent.rule_ids.values.map { |r| r["hook"] }
    Install::Installer::HOOKS.values.flatten.each do |script|
      assert_includes declared, script.sub(/\.rb\z/, ""), "#{script} has no rule in config/rule_ids.yml"
    end
  end

  def test_every_installer_hook_entry_point_is_instrumented
    Install::Installer::HOOKS.values.flatten.each do |script|
      source = File.read(File.expand_path("../scripts/#{script}", __dir__))
      assert_includes source, "HookEvent.instrument('#{script.sub(/\.rb\z/, '')}'", "#{script} is not instrumented"
    end
  end
end
