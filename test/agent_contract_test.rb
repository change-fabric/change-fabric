# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../scripts/cf_host_hook"
require_relative "../scripts/skill_compiler"

# Real subprocess wire-format tests, without a model or network service.
class AgentContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCENARIOS = JSON.parse(File.read(File.join(__dir__, "fixtures/agents/contracts.json"))).fetch("scenarios")

  def setup
    @home = Dir.mktmpdir
    @project = File.join(@home, "project")
    FileUtils.mkdir_p(@project)
    system("git", "init", "-q", "-b", "feature", @project, exception: true)
  end

  def teardown = FileUtils.remove_entry(@home)

  def wire(host, event, payload)
    env = { "HOME" => @home, "CF_STATE_HOME" => File.join(@home, "state") }
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, "scripts/cf_host_hook.rb"), host, event,
      stdin_data: JSON.generate({ "cwd" => @project, "session_id" => "parent" }.merge(payload)))
    assert status.success?, err
    JSON.parse(out)
  end

  def test_same_scenarios_through_all_native_wire_formats
    SkillCompiler::HOSTS.each do |host|
      SCENARIOS.each do |scenario|
        wire(host, "UserPromptSubmit", "prompt" => "$cf-#{scenario['mode']}")
        payload = if host == "copilot"
          { "toolName" => "bash", "toolArgs" => JSON.generate("command" => scenario["command"]) }
        else
          { "tool_name" => host == "codex" ? "exec_command" : "bash", "tool_input" => { "cmd" => scenario["command"], "command" => scenario["command"] } }
        end
        result = wire(host, host == "copilot" ? "preToolUse" : "PreToolUse", payload)
        denied = host == "copilot" ? result["permissionDecision"] == "deny" : result.dig("hookSpecificOutput", "permissionDecision") == "deny"
        assert_equal scenario["deny"], denied, "#{host}: #{scenario}"
      end
    end
  end

  def test_resume_child_inheritance_and_independent_session
    wire("codex", "UserPromptSubmit", "prompt" => "$cf-local-only")
    child = wire("codex", "SubagentStart", "agent_id" => "child")
    assert_includes child.dig("hookSpecificOutput", "additionalContext"), "local-only"
    resumed = wire("codex", "SessionStart", {})
    assert_includes resumed.dig("hookSpecificOutput", "additionalContext"), "local-only"
    other = wire("codex", "SessionStart", "session_id" => "independent")
    assert_includes other.dig("hookSpecificOutput", "additionalContext"), "merge-ready"
  end

  # Hooks fail silent: denying on an internal error would wedge every tool,
  # including the shell the agent needs to recover.
  def test_malformed_pretool_input_fails_silent_with_a_warning
    out, err, status = Open3.capture3({ "HOME" => @home }, RbConfig.ruby,
      File.join(ROOT, "scripts/cf_host_hook.rb"), "codex", "PreToolUse", stdin_data: "broken JSON")
    assert_equal 0, status.exitstatus
    assert_includes err, "adapter error"
    assert_equal({}, JSON.parse(out))
  end

  def test_reported_roast_invocation_is_rendered_with_native_codex_name
    compiler = SkillCompiler.new(host: "codex")
    assert_equal "$cf-roast", compiler.references("/cf:roast")
    assert_equal "$cf-roast", compiler.references("{{skill:roast}}")
    text = compiler.compile(File.read(File.join(ROOT, "skills/roast/SKILL.md")))
    refute_includes text, "`/cf:roast"
    assert_includes text, "$cf-roast"
  end
end
