# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
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

  def test_plain_pre_tool_call_carries_no_rubric_to_block_on
    result = hook("opencode", "PreToolUse", "tool_name" => "bash", "tool_input" => { "command" => "ls" })
    refute result.dig("hookSpecificOutput", "rubricContext")
  end

  def test_environment_default_mode_keeps_a_resumed_explicit_choice
    hook("pi", "UserPromptSubmit", "prompt" => "/skill:cf-local-only")
    hook("pi", "UserPromptSubmit", "prompt" => "/skill:cf-merge-ready", "cf_default" => true)
    assert_includes hook("pi", "SessionStart").dig("hookSpecificOutput", "additionalContext"), "local-only"
  end

  def test_away_session_refuses_planning_interviews
    hook("claude", "UserPromptSubmit", "prompt" => "/cf:away")
    refusal = hook("claude", "UserPromptSubmit", "prompt" => "/cf:plan ship it").dig("hookSpecificOutput", "additionalContext")
    assert_includes refusal, "refuse to start the cf:plan interview"
    quick = hook("claude", "UserPromptSubmit", "prompt" => "/cf:drive quick 12").dig("hookSpecificOutput", "additionalContext")
    refute_includes quick, "refuse to start"
  end

  def context(host, event, payload = {}) = hook(host, event, payload).dig("hookSpecificOutput", "additionalContext").to_s

  def test_away_context_tells_the_agent_not_to_ask
    hook("claude", "UserPromptSubmit", "prompt" => "/cf:away")
    %w[SessionStart UserPromptSubmit].each do |event|
      text = context("claude", event)
      assert_includes text, "Do not ask questions; take the recommended/safe default and continue; report what was assumed"
      assert_includes text, "Run /cf:active to end away mode"
    end
    hook("claude", "UserPromptSubmit", "prompt" => "/cf:active")
    refute_includes context("claude", "SessionStart"), "Do not ask questions"
  end

  def test_mode_commands_confirm_the_change
    assert_includes context("claude", "UserPromptSubmit", "prompt" => "/cf:yolo"), "Merge mode for this session is now yolo"
    assert_includes context("claude", "UserPromptSubmit", "prompt" => "/cf:away"), "Away mode is now on"
    assert_includes context("claude", "UserPromptSubmit", "prompt" => "/cf:active"), "Away mode is now off"
    assert_includes context("claude", "SessionStart"), "run /cf:local-only, /cf:merge-ready, /cf:admin-bypass, /cf:yolo, or /cf to change it"
  end

  def test_merge_mode_denial_says_how_to_change_the_mode
    hook("claude", "UserPromptSubmit", "prompt" => "/cf:local-only")
    reason = hook("claude", "PreToolUse", "tool_name" => "Bash", "tool_input" => { "command" => "git push" }).dig("hookSpecificOutput", "permissionDecisionReason")
    assert_includes reason, "[cf] Merge mode is local-only: git push is not allowed"
    assert_includes reason, "or /cf to change the mode"
  end

  def test_away_question_denial_names_away_and_the_floor
    hook("claude", "UserPromptSubmit", "prompt" => "/cf:away")
    ask = { "tool_name" => "AskUserQuestion", "tool_input" => { "questions" => [ { "header" => "Scope" } ] } }
    reason = hook("claude", "PreToolUse", ask).dig("hookSpecificOutput", "permissionDecisionReason")
    assert_includes reason, "Away mode is active: this question (Scope)"
    assert_includes reason, "Remote delete, Untracked, Secret alert"
    assert_includes reason, "report what was assumed"
    assert_includes reason, "/cf:active"
    refute_includes reason, "Merge mode"
  end

  def test_allowed_tool_calls_carry_no_context
    assert_empty hook("claude", "PreToolUse", "tool_name" => "Bash", "tool_input" => { "command" => "ls" })
    assert_empty hook("codex", "PostToolUse", "tool_name" => "exec_command", "tool_input" => { "cmd" => "ls" })
    assert_empty hook("copilot", "postToolUse", "toolName" => "bash", "toolArgs" => '{"command":"ls"}')
    refute_includes context("claude", "SessionStart"), "advisory"
    assert_includes context("opencode", "SessionStart"), "advisory"
  end

  def test_free_form_away_answer_records_active
    hook("claude", "UserPromptSubmit", "prompt" => "/cf:away")
    answer = { "tool_name" => "AskUserQuestion", "tool_input" => { "questions" => [ { "header" => "Scope" } ] },
               "tool_response" => { "questions" => [ { "header" => "Away mode", "question" => "Away?" } ],
                                     "answers" => { "Away?" => "back in an hour" } } }
    hook("claude", "PostToolUse", answer)
    assert_includes context("claude", "SessionStart"), "availability: active"
  end

  def run_script(payload)
    env = { "HOME" => @home, "CF_STATE_HOME" => File.join(@home, "state") }
    script = File.expand_path("../scripts/cf_host_hook.rb", __dir__)
    Open3.capture3(env, RbConfig.ruby, script, "claude", "PreToolUse", stdin_data: JSON.generate(payload), chdir: @home)
  end

  def test_deleted_cwd_allows_silently
    gone = File.join(@home, "removed-worktree")
    out, err, status = run_script("session_id" => "one", "cwd" => gone, "tool_name" => "Bash", "tool_input" => { "command" => "cd /" })
    assert status.success?
    assert_equal({}, JSON.parse(out))
    assert_includes err, "[cf] adapter error"
  end

  def test_corrupt_state_allows_silently
    project = File.realpath(@home)
    dir = File.join(@home, "state", "sessions", "claude", Digest::SHA256.hexdigest(project))
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{Digest::SHA256.hexdigest('one')}.json"), "{not json")
    out, err, status = run_script(@payload.merge("tool_name" => "Bash", "tool_input" => { "command" => "git push" }))
    assert status.success?
    assert_equal({}, JSON.parse(out))
    assert_includes err, "[cf] adapter error"
  end
end
