# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/roast"
require_relative "../scripts/roast_codex"

class RoastCodexTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/roast_codex", __dir__)

  def fixture(name) = File.read(File.join(FIXTURES, name))

  # A login-status fixture ends with an "exit=N" line the capture appended.
  def status_result(name)
    text = fixture(name)
    code = text[/^exit=(\d+)\s*\z/, 1].to_i
    RoastCodex::Result.new(stdout: text.sub(/^exit=\d+\s*\z/, ""), stderr: "", exit_code: code, timed_out: false)
  end

  def result(stdout, exit_code: 0, stderr: "")
    RoastCodex::Result.new(stdout: stdout, stderr: stderr, exit_code: exit_code, timed_out: false)
  end

  # A runner that writes the -o answer (when given) and returns the canned result.
  def runner_for(res, answer: nil)
    lambda do |argv, **kw|
      next status_result("login_status_chatgpt.txt") if argv.include?("login")
      next result(fixture("models.json")) if argv.include?("debug")

      @seen = { argv: argv, **kw }
      File.write(argv[argv.index("-o") + 1], answer) if answer
      res
    end
  end

  def call_with(res, answer: nil, env: {})
    RoastCodex.call(system: "SYS", user: "USER", images: [ "/tmp/a.png" ], model: "gpt-5.6-terra", effort: "low",
                    schema: Roast::SCHEMA, validate: Roast.method(:validate_critic!), runner: runner_for(res, answer: answer), env: env)
  end

  def test_argv_shape
    argv = RoastCodex.build_argv(model: "m", effort: "low", images: %w[/a.png /b.png], schema_path: "/s.json", out_path: "/o.json", dir: "/d")
    assert_equal %w[codex exec -i /a.png -i /b.png --json -s read-only --ephemeral --skip-git-repo-check --ignore-user-config --ignore-rules
                    -C /d -m m -c model_reasoning_effort=low --output-schema /s.json -o /o.json -], argv
  end

  def test_command_override_is_shell_split
    assert_equal [ "/x/node", "/x/codex" ], RoastCodex.command("CF_ROAST_CODEX" => "/x/node /x/codex")
    assert_equal %w[codex], RoastCodex.command({})
  end

  def test_prompt_prepends_system_with_delimiter
    assert_equal "SYS#{RoastCodex::PROMPT_DELIMITER}USER", RoastCodex.prompt(system: "SYS", user: "USER")
  end

  def test_child_env_scrubs_keys_and_sets_sentinel
    env = { "OPENAI_API_KEY" => "a", "CODEX_API_KEY" => "b", "CF_TELEMETRY_TOKEN" => "c", "CF_SECRETS_ENV" => "d",
            "GEMINI_API_KEY" => "e", "HOME" => "/h", "PATH" => "/bin", "CF_STATE_HOME" => "/s" }
    child = RoastCodex.child_env(env)
    assert_equal({ "HOME" => "/h", "PATH" => "/bin", "CF_STATE_HOME" => "/s", "CF_ROAST_CRITIC" => "1" }, child)
  end

  def test_call_passes_scrubbed_env_and_prompt
    call_with(result(fixture("exec_ok.jsonl")), answer: fixture("exec_ok_last.json"), env: { "OPENAI_API_KEY" => "x", "PATH" => "/bin" })
    refute @seen[:env].key?("OPENAI_API_KEY")
    assert_equal "1", @seen[:env]["CF_ROAST_CRITIC"]
    assert_equal "SYS#{RoastCodex::PROMPT_DELIMITER}USER", @seen[:stdin]
  end

  def test_relative_image_paths_are_absolute_in_the_child_argv
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        RoastCodex.call(system: "S", user: "U", images: [ "shot.png" ], model: "m", effort: "low", schema: Roast::SCHEMA,
                        validate: ->(_) { }, runner: runner_for(result(fixture("exec_ok.jsonl")), answer: fixture("exec_ok_last.json")), env: {})
        assert_equal File.join(File.realpath(dir), "shot.png"), File.realpath(File.dirname(@seen[:argv][@seen[:argv].index("-i") + 1])) + "/shot.png"
      end
    end
  end

  def test_login_status_from_fixtures
    assert_equal [ :ok ], RoastCodex.available?(runner: ->(*, **) { status_result("login_status_chatgpt.txt") }, env: {})
    assert_equal [ :unavailable, :not_logged_in ], RoastCodex.available?(runner: ->(*, **) { status_result("login_status_logged_out.txt") }, env: {})
  end

  def test_missing_binary_is_unavailable
    assert_equal [ :unavailable, :missing ], RoastCodex.available?(env: { "CF_ROAST_CODEX" => "/nonexistent/codex", "PATH" => "/nonexistent" })
  end

  def test_probe_errors_never_fall_back
    crash = ->(*, **) { raise "boom" }
    garbage = ->(*, **) { result("hello world", exit_code: 0) }
    api_key = ->(*, **) { result("Logged in using an API key - sk-proj-***", exit_code: 0) }
    hung = ->(*, **) { RoastCodex::Result.new(stdout: "", stderr: "", exit_code: nil, timed_out: true) }
    [ crash, garbage, api_key, hung ].each do |runner|
      assert_equal :error, RoastCodex.available?(runner: runner, env: {}).first
      error = assert_raises(RoastCodex::Failed) { RoastCodex.ensure_available!(runner: runner, env: {}) }
      assert_equal :probe, error.reason
    end
  end

  def test_ensure_available_raises_unavailable
    error = assert_raises(RoastCodex::Unavailable) do
      RoastCodex.ensure_available!(runner: ->(*, **) { status_result("login_status_logged_out.txt") }, env: {})
    end
    assert_equal :not_logged_in, error.reason
  end

  def test_ok_parse_from_fixtures
    answer = call_with(result(fixture("exec_ok.jsonl")), answer: fixture("exec_ok_last.json"))
    assert_equal 3, answer.critic["score"]
    assert_equal 19_263, answer.subscription_tokens
  end

  def test_usage_limit_event_is_unavailable
    error = assert_raises(RoastCodex::Unavailable) { call_with(result(fixture("exec_usage_limit.jsonl"), exit_code: 1)) }
    assert_equal :limit, error.reason
  end

  def test_limit_event_wins_even_with_exit_zero
    assert_raises(RoastCodex::Unavailable) { call_with(result(fixture("exec_usage_limit.jsonl"), exit_code: 0)) }
  end

  def test_rejected_models_from_fixtures
    %w[exec_model_rejected.jsonl exec_model_too_new.jsonl].each do |name|
      error = assert_raises(RoastCodex::Rejected) { call_with(result(fixture(name), exit_code: 1)) }
      assert_equal :model, error.reason
    end
  end

  def test_schema_invalid_answer_is_failed_schema
    bad = JSON.generate(JSON.parse(fixture("exec_ok_last.json")).merge("score" => 42))
    error = assert_raises(RoastCodex::Failed) { call_with(result(fixture("exec_ok.jsonl")), answer: bad) }
    assert_equal :schema, error.reason
  end

  def test_missing_or_garbled_answer_file_is_failed_schema
    assert_equal :schema, assert_raises(RoastCodex::Failed) { call_with(result(fixture("exec_ok.jsonl"))) }.reason
    assert_equal :schema, assert_raises(RoastCodex::Failed) { call_with(result(fixture("exec_ok.jsonl")), answer: "{nope") }.reason
  end

  def test_nonzero_exit_without_limit_event_is_crash
    error = assert_raises(RoastCodex::Failed) { call_with(result(fixture("exec_ok.jsonl"), exit_code: 2), answer: fixture("exec_ok_last.json")) }
    assert_equal :crash, error.reason
  end

  def test_non_limit_error_event_with_exit_zero_is_crash
    stream = [ '{"type":"turn.started"}', '{"type":"error","message":"something odd"}', '{"type":"turn.completed","usage":{}}' ].join("\n")
    error = assert_raises(RoastCodex::Failed) { call_with(result(stream), answer: fixture("exec_ok_last.json")) }
    assert_equal :crash, error.reason
  end

  def test_exit_zero_without_turn_completed_is_crash
    stream = fixture("exec_ok.jsonl").lines.reject { |l| l.include?("turn.completed") }.join
    error = assert_raises(RoastCodex::Failed) { call_with(result(stream), answer: fixture("exec_ok_last.json")) }
    assert_equal :crash, error.reason
  end

  def test_quota_phrase_in_critic_text_is_not_a_limit
    critic = JSON.parse(fixture("exec_ok_last.json")).merge("summary" => "You've hit your usage limit for this widget")
    answer = call_with(result(fixture("exec_ok.jsonl")), answer: JSON.generate(critic))
    assert_includes answer.critic["summary"], "usage limit"
  end

  def test_quota_phrase_in_stderr_with_nonzero_exit_is_crash
    error = assert_raises(RoastCodex::Failed) do
      call_with(result("", exit_code: 1, stderr: "You've hit your usage limit for GPT"), answer: nil)
    end
    assert_equal :crash, error.reason
  end

  def test_timeout_kills_the_process_group
    script = File.join(FIXTURES, "fake_codex_sleep")
    Dir.mktmpdir do |dir|
      out = File.join(dir, "last.json")
      started = Time.now
      res = RoastCodex.run_process([ script, "-o", out ], env: { "PATH" => ENV.fetch("PATH") }, stdin: "", timeout: 1, chdir: dir, grace: 1)
      assert res.timed_out
      assert_operator Time.now - started, :<, 10
      pids = File.read("#{out}.pids").split.map(&:to_i)
      assert_equal 2, pids.size
      pids.each { |pid| assert_raises(Errno::ESRCH) { Process.kill(0, pid) } }
    end
  end

  def test_call_raises_failed_timeout
    timed_out = ->(*, **) { RoastCodex::Result.new(stdout: "", stderr: "", exit_code: nil, timed_out: true) }
    error = assert_raises(RoastCodex::Failed) do
      RoastCodex.call(system: "s", user: "u", images: [], model: "m", effort: "low", schema: Roast::SCHEMA,
                      validate: ->(_) { }, runner: timed_out, env: { "CF_ROAST_CODEX_TIMEOUT" => "1" })
    end
    assert_equal :timeout, error.reason
  end

  def test_backend_resolution_and_cache_key
    assert_equal "auto", Roast.backend_for(env: {})
    assert_equal "codex", Roast.backend_for(env: { "CF_ROAST_BACKEND" => "codex" })
    assert_equal "api", Roast.backend_for(flag: "api", env: { "CF_ROAST_BACKEND" => "codex" })
    assert_raises(Roast::UsageError) { Roast.backend_for(flag: "nope") }
    Dir.mktmpdir do |dir|
      shot = File.join(dir, "s.png")
      FileUtils.cp(File.join(FIXTURES, "tiny64.png"), shot)
      base = { brief: "b", shots: [ shot ], history: [], round: 1 }
      refute_equal Roast.request_key(**base), Roast.request_key(**base, backend: "codex")
      assert_equal Roast.request_key(**base), Roast.request_key(**base, backend: "api")
    end
  end

  def test_video_refuses_under_codex
    out = StringIO.new
    code = Roast::Cli.run([ "--video", "x.mp4", "--backend", "codex" ], out: out)
    assert_equal 1, code
    assert_includes out.string, "roast: --video is API-only; --backend codex cannot film"
  end

  def test_critique_through_codex_caches_under_the_codex_key
    Dir.mktmpdir do |dir|
      shot = File.join(dir, "s.png")
      FileUtils.cp(File.join(FIXTURES, "tiny64.png"), shot)
      runner = runner_for(result(fixture("exec_ok.jsonl")), answer: fixture("exec_ok_last.json"))
      args = { brief: "b", shots: [ shot ], history: [], round: 1, cache_root: File.join(dir, "cache"), backend: "codex",
               codex_runner: runner, env: { "PATH" => "/bin" }, out: StringIO.new }
      critic = Roast.critique(**args)
      assert_equal 3, critic["score"]
      calls = 0
      again = Roast.critique(**args.merge(codex_runner: ->(*, **) { calls += 1 }))
      assert_equal 0, calls
      assert_equal critic, again
    end
  end

  def test_pinned_and_tier_selections_never_share_a_codex_cache_entry
    Dir.mktmpdir do |dir|
      shot = File.join(dir, "s.png")
      FileUtils.cp(File.join(FIXTURES, "tiny64.png"), shot)
      models = []
      runner = lambda do |argv, **kw|
        next status_result("login_status_chatgpt.txt") if argv.include?("login")
        next result(fixture("models.json")) if argv.include?("debug")

        models << argv[argv.index("-m") + 1]
        runner_for(result(fixture("exec_ok.jsonl")), answer: fixture("exec_ok_last.json")).call(argv, **kw)
      end
      args = { brief: "b", shots: [ shot ], history: [], round: 1, cache_root: File.join(dir, "cache"), backend: "codex",
               codex_runner: runner, env: { "PATH" => "/bin" }, out: StringIO.new, model: "gpt-6.1-terra" }
      Roast.critique(**args)
      Roast.critique(**args, pin: { model: true })
      Roast.critique(**args, pin: { model: true })
      assert_equal %w[gpt-6.2-sol gpt-6.1-terra], models
    end
  end
end
