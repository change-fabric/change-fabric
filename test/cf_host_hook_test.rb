# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/cf_host_hook"
require_relative "../scripts/native_hook_install"

class CfHostHookTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @payload = { "session_id" => "one", "cwd" => @home }
  end

  def teardown = FileUtils.remove_entry(@home)

  def hook(host, event, payload = {})
    CfHostHook.new(host: host, event: event, payload: @payload.merge(payload), root: File.join(@home, "state"), home: @home, skills: []).call
  end

  def test_codex_native_invocation_persists_and_blocks_unified_exec
    hook("codex", "UserPromptSubmit", "prompt" => "$cf-local-only work")
    result = hook("codex", "PreToolUse", "tool_name" => "exec_command", "tool_input" => { "cmd" => "git push origin feature" })
    assert_equal "deny", result.dig("hookSpecificOutput", "permissionDecision")
    assert_includes hook("codex", "SessionStart").dig("hookSpecificOutput", "additionalContext"), "local-only"
  end

  def test_copilot_camel_case_payload_and_flat_deny
    hook("copilot", "userPromptSubmitted", "sessionId" => "two", "prompt" => "$cf-local-only")
    result = hook("copilot", "preToolUse", "sessionId" => "two", "toolName" => "bash", "toolArgs" => '{"command":"git push"}')
    assert_equal "deny", result["permissionDecision"]
    refute result.key?("hookSpecificOutput")
  end

  def test_successful_skill_load_changes_mode_but_failed_load_does_not
    payload = { "tool_name" => "skill", "tool_input" => { "name" => "cf-local-only" } }
    hook("opencode", "PostToolUse", payload.merge("isError" => true))
    assert_includes hook("opencode", "SessionStart").dig("hookSpecificOutput", "additionalContext"), "merge-ready"
    hook("opencode", "PostToolUse", payload)
    assert_includes hook("opencode", "SessionStart").dig("hookSpecificOutput", "additionalContext"), "local-only"
  end

  def test_native_hook_install_preserves_foreign_hooks_and_is_idempotent
    file = File.join(@home, "hooks.json")
    foreign = { "hooks" => [ { "type" => "command", "command" => "echo hello" } ] }
    File.write(file, JSON.generate("hooks" => { "PreToolUse" => [ foreign ] }))
    install = NativeHookInstall.new(path: file, host: "codex", ruby: "/ruby with space", bin: "/cf bin")
    2.times { install.wire }
    entries = JSON.parse(File.read(file)).dig("hooks", "PreToolUse")
    assert_equal foreign, entries.first
    assert_equal 2, entries.length
    assert File.file?("#{file}.bak")
  end

  def test_missing_session_is_an_error_instead_of_shared_directory_identity
    assert_raises(ArgumentError) { hook("codex", "SessionStart", "session_id" => nil) }
  end
end
