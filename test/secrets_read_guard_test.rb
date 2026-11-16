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

  def test_pathless_search_from_inside_the_secrets_dir_is_denied
    FileUtils.mkdir_p(File.join(@secrets, "abc"))
    assert_equal "deny", decide("Grep", { "pattern" => "sk-" }, cwd: File.join(@secrets, "abc"))
    assert_equal "deny", decide("Glob", { "pattern" => "**/*" }, cwd: @secrets)
    assert_nil decide("Grep", { "pattern" => "sk-" }, cwd: @home)
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

  def test_env_files_are_denied_to_file_tools
    project = File.join(@home, "project")
    assert_equal "deny", decide("Read", "file_path" => File.join(project, ".env"))
    assert_equal "deny", decide("Read", "file_path" => File.join(project, ".env.local"))
    assert_equal "deny", decide("Edit", "file_path" => File.join(project, ".env.production"))
    assert_equal "deny", decide("Write", "file_path" => ".env.local.bak")
    assert_equal "deny", decide("Grep", "pattern" => "KEY", "path" => File.join(project, ".env"))
    assert_equal "deny", decide("Grep", "pattern" => "KEY", "path" => project, "glob" => ".env.local")
  end

  def test_env_reason_names_the_push_verb
    io = StringIO.new
    SecretsReadGuard.new({ "tool_name" => "Read", "tool_input" => { "file_path" => ".env" }, "cwd" => @home }, home: @home).emit(io)
    reason = JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecisionReason")
    assert_includes reason, "[cf:secret-intake]"
    assert_includes reason, "push NAME --to env:"
  end

  def test_symlink_to_an_env_file_is_denied
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, ".env"), "")
    File.symlink(File.join(project, ".env"), File.join(project, "settings.txt"))
    assert_equal "deny", decide("Read", "file_path" => File.join(project, "settings.txt"))
  end

  def test_env_templates_and_lookalikes_are_allowed
    project = File.join(@home, "project")
    [ ".env.example", ".env.sample", ".env.template", "config.template", ".envrc", "src/.envrc", "dotenv.rb" ].each do |name|
      assert_nil decide("Read", "file_path" => File.join(project, name)), name
    end
  end

  def test_shell_reads_of_env_files_are_denied
    [ "cat .env", "cat .env.production", "source .env", ". ./.env.local", "head -n 3 app/.env",
      "grep KEY .env.local", "sed -n 1p $HOME/proj/.env", "less '.env'", "docker run --env-file=.env img" ].each do |cmd|
      assert_equal "deny", decide("Bash", "command" => cmd), cmd
    end
  end

  def test_shell_commands_on_env_templates_are_allowed
    [ "cat .env.example", "cp .env.sample /dev/null", "ls src/.envrc", "git status", "echo $NODE_ENV" ].each do |cmd|
      assert_nil decide("Bash", "command" => cmd), cmd
    end
  end

  def test_secret_intake_push_to_an_env_file_is_allowed_only_bare
    push = "ruby ~/.claude/cf/bin/secret_intake.rb push X --to env:.env.local"
    assert_nil decide("Bash", "command" => push)
    assert_equal "deny", decide("Bash", "command" => "#{push} | cat")
    assert_equal "deny", decide("Bash", "command" => "#{push} && cat .env.local")
    assert_equal "deny", decide("Bash", "command" => "#{push}; cat .env.local")
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

  def test_guard_only_prompts_run_the_paste_guard_and_nothing_else
    blocked = host("opencode", "UserPromptSubmit", "prompt" => "key AIza#{'Q' * 35}", "guard_only" => true)
    assert_equal "block", blocked["decision"]
    refute_includes JSON.generate(blocked), "AIza"
    assert_equal({}, host("opencode", "UserPromptSubmit", "prompt" => "/cf:yolo", "guard_only" => true))
  end

  # Pi and OpenCode must enforce the block, not just read context from it.
  def test_pi_and_opencode_extensions_enforce_a_prompt_block
    root = File.expand_path("../extensions", __dir__)
    pi = File.read(File.join(root, "pi-cf-hooks", "index.ts"))
    assert_match(/result\.decision === "block"[^}]*action: "handled"/m, pi)
    opencode = File.read(File.join(root, "opencode-cf-hooks", "index.ts"))
    chat = opencode[opencode.index('"chat.message"')...opencode.index('"experimental.chat.system.transform"')]
    assert_includes chat, "prompt, guard_only: true"
    assert_match(/decision !== "block"/, chat)
    assert_match(/part\.text = notice/, chat)
  end
end
