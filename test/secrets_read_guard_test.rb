# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../scripts/secrets_read_guard"
require_relative "../scripts/cf_host_hook"

class SecretsReadGuardTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/secrets_read_guard.rb", __dir__)

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @secrets = File.join(@home, ".claude", "cf", "secrets")
  end

  def teardown = FileUtils.remove_entry(@home)

  # Braceless string-keyed args arrive as keywords; fold them into the input.
  def decide(tool, input = {}, cwd: @home, **fields)
    input = input.merge(fields.transform_keys(&:to_s))
    io = StringIO.new
    SecretsReadGuard.new({ "tool_name" => tool, "tool_input" => input, "cwd" => cwd }, home: @home).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecision")
  end

  def test_file_tools_under_the_secrets_dir_are_denied
    path = File.join(@secrets, "abc", ".openai")
    assert_equal "deny", decide("Read", "file_path" => path)
    assert_equal "deny", decide("Edit", "file_path" => path)
    assert_equal "deny", decide("Write", "file_path" => path)
    assert_equal "deny", decide("Grep", "pattern" => "sk-", "path" => @secrets)
    assert_equal "deny", decide("Glob", "pattern" => "**/*", "path" => File.join(@secrets, "abc"))
    assert_equal "deny", decide("Glob", "pattern" => "~/.claude/cf/secrets/**")
    assert_equal "deny", decide("Read", "file_path" => "~/.claude/cf/secrets/abc/meta.json")
  end

  def test_relative_and_symlinked_paths_are_resolved
    FileUtils.mkdir_p(File.join(@secrets, "abc"))
    assert_equal "deny", decide("Read", { "file_path" => "secrets/abc/.openai" }, cwd: File.join(@home, ".claude", "cf"))
    link = File.join(@home, "innocent")
    File.symlink(@secrets, link)
    assert_equal "deny", decide("Read", "file_path" => File.join(link, "abc", ".openai"))
  end

  def test_other_paths_are_allowed
    assert_nil decide("Read", "file_path" => File.join(@home, ".claude", "cf", "secrets-notes.md"))
    assert_nil decide("Read", "file_path" => File.join(@home, "project", "README.md"))
    assert_nil decide("Grep", "pattern" => "x", "path" => File.join(@home, "project"))
  end

  def test_shell_commands_naming_the_secrets_dir_are_denied
    assert_equal "deny", decide("Bash", "command" => "cat ~/.claude/cf/secrets/x/.openai")
    assert_equal "deny", decide("Bash", "command" => "ls $HOME/.claude/cf/secrets")
    assert_equal "deny", decide("Bash", "command" => "cd ~/.claude && cat cf/secrets/x/.gemini")
    assert_equal "deny", decide("Bash", "command" => "ruby ~/.claude/cf/bin/cf_keys.rb status; cat ~/.claude/cf/secrets/x/.openai")
  end

  def test_cf_keys_runs_are_allowed
    assert_nil decide("Bash", "command" => "ruby ~/.claude/cf/bin/cf_keys.rb status")
    assert_nil decide("Bash", "command" => "ruby ~/.claude/cf/bin/cf_keys.rb defer gemini --dir '#{@home}/proj'")
    assert_nil decide("Bash", "command" => "git status")
  end

  def test_malformed_stdin_exits_0_silently
    [ "not json", "[]", "", "{\"tool_name\": \"Read\", \"tool_input\": 3}" ].each do |stdin|
      out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, stdin_data: stdin)
      assert status.success?, stdin
      assert_empty out, stdin
      assert_empty err, stdin
    end
  end

  def host(host, event, payload)
    CfHostHook.new(host: host, event: event, payload: { "session_id" => "s", "cwd" => @home }.merge(payload),
                   root: File.join(@home, "state"), home: @home, skills: []).call
  end

  def test_codex_and_copilot_mirror_the_read_guard
    codex = host("codex", "PreToolUse", "tool_name" => "exec_command", "tool_input" => { "cmd" => "cat ~/.claude/cf/secrets/a/.openai" })
    assert_equal "deny", codex.dig("hookSpecificOutput", "permissionDecision")
    copilot = host("copilot", "preToolUse", "toolName" => "view", "toolArgs" => JSON.generate("path" => File.join(@secrets, "a", ".openai")))
    assert_equal "deny", copilot["permissionDecision"]
  end

  def test_codex_mirrors_the_paste_guard
    out = host("codex", "UserPromptSubmit", "prompt" => "key AIza#{'Q' * 35}")
    assert_equal "block", out["decision"]
  end
end
