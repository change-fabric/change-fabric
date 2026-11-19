# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require_relative "support/totp_enrollment"
require_relative "../scripts/approval_console"
require_relative "../scripts/approval_console/terminal_prompt"

class ApprovalConsoleCliTest < Minitest::Test
  include TotpEnrollment

  Totp = ApprovalConsole::Totp
  FakeTty = Struct.new(:tty_value, :answer) do
    def tty? = tty_value
    def gets = answer
  end

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    @store = ApprovalConsole::LocalStore.new
    @t0 = Time.at(1_800_000_000)
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def cli(argv, tty: true, env: {}, parents: [], reveal: StringIO.new, now: @t0)
    out = StringIO.new
    err = StringIO.new
    status = ApprovalConsoleCli.run(argv, stdin: FakeTty.new(tty, "\n"), stdout: out, stderr: err, env: env,
                                          store: @store, tty_open: -> { reveal }, parents: -> { parents }, now: now)
    [ status, out.string, err.string ]
  end

  def code(step_offset = 0, time: @t0) = Totp.code(@store.seed, Totp.step_for(time) + step_offset)

  def consume(value, time: @t0, entry: nil) = @store.consume(value, now: time, entry: entry)

  # --- enroll ---

  def test_enroll_writes_a_0600_seed_and_shows_it_only_on_the_tty
    reveal = StringIO.new
    status, out, err = cli(%w[totp-enroll], reveal: reveal)
    assert_equal 0, status
    assert @store.enrolled?
    secret = ApprovalConsole::Base32.encode(@store.seed)
    assert_includes reveal.string, secret
    assert_includes reveal.string, "\e[?1049h"
    assert_includes reveal.string, "\e[?1049l"
    refute_includes out, secret
    refute_includes err, secret
    assert_equal 0o600, File.stat(@store.path("totp_seed")).mode & 0o777
    assert_equal 0o700, File.stat(@store.dir).mode & 0o777
    assert_match(/\A[0-9a-f-]{36}\z/, @store.machine_id)
  end

  def test_enroll_refuses_without_a_tty_on_stdin
    status, _out, err = cli(%w[totp-enroll], tty: false)
    assert_equal 2, status
    assert_match(/real terminal/, err)
    refute @store.enrolled?
  end

  def test_enroll_refuses_inside_an_agent_harness
    %w[CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX OPENCODE PI_AGENT].each do |name|
      status, _out, err = cli(%w[totp-enroll], env: { name => "1" })
      assert_equal 2, status, name
      assert_match(/agent harness/, err)
    end
    refute @store.enrolled?
  end

  def test_enroll_refuses_under_an_agent_parent_process
    status, = cli(%w[totp-enroll], parents: %w[zsh claude login])
    assert_equal 2, status
    refute @store.enrolled?
  end

  def test_enroll_refuses_when_dev_tty_cannot_be_opened
    out = StringIO.new
    err = StringIO.new
    status = ApprovalConsoleCli.run(%w[totp-enroll], stdin: FakeTty.new(true, ""), stdout: out, stderr: err, env: {},
                                                     store: @store, tty_open: -> { }, parents: -> { [] })
    assert_equal 2, status
    assert_match(%r{/dev/tty}, err.string)
    refute @store.enrolled?
  end

  def test_enroll_never_overwrites_an_existing_seed
    enroll_totp(@home)
    before = @store.seed
    status, _out, err = cli(%w[totp-enroll])
    assert_equal 2, status
    assert_match(/already enrolled/, err)
    assert_equal before, @store.seed
  end

  def test_a_failed_reveal_discards_the_seed
    broken = Object.new
    def broken.print(*) = raise(Errno::EIO)
    def broken.puts(*) = raise(Errno::EIO)
    status, _out, err = cli(%w[totp-enroll], reveal: broken)
    assert_equal 1, status
    assert_match(/nothing was enrolled/, err)
    refute @store.enrolled?
  end

  def test_an_interrupted_reveal_discards_the_seed
    interrupted = Object.new
    def interrupted.print(*) = true
    def interrupted.puts(*) = true
    def interrupted.flush = true
    def interrupted.gets = raise(Interrupt)
    assert_raises(Interrupt) { cli(%w[totp-enroll], reveal: interrupted) }
    refute @store.enrolled?
    assert_equal 0, cli(%w[totp-enroll]).first, "a later enroll can show a fresh secret"
  end

  # --- status and unlock ---

  def test_status_prints_state_and_never_the_seed
    enroll_totp(@home)
    consume(code)
    _status, out, err = cli(%w[status])
    assert_match(/enrolled: yes/, out)
    assert_match(/last accepted step: #{Totp.step_for(@t0)}/, out)
    assert_match(/host: ok/, out)
    secret = ApprovalConsole::Base32.encode(@store.seed)
    refute_includes out + err, secret
    refute_includes out + err, @store.seed.unpack1("H*")
  end

  def test_status_works_without_a_tty_and_reports_unenrolled
    status, out, = cli(%w[status], tty: false)
    assert_equal 0, status
    assert_match(/enrolled: no/, out)
  end

  def test_status_reports_a_degraded_host
    enroll_totp(@home)
    File.chmod(0o755, @store.dir)
    _status, out, = cli(%w[status])
    assert_match(/degraded/, out)
    assert_match(/not 700/, out)
  end

  def test_unlock_refuses_on_a_terminal_only_install
    enroll_totp(@home)
    status, _out, err = cli(%w[unlock])
    assert_equal 2, status
    assert_match(/no manual unlock/, err)
  end

  def test_unlock_refuses_without_a_tty_and_in_an_agent_harness
    assert_equal 2, cli(%w[unlock], tty: false).first
    assert_equal 2, cli(%w[unlock], env: { "CLAUDECODE" => "1" }).first
  end

  def test_unlock_does_not_clear_a_lockout
    enroll_totp(@home)
    5.times { consume("000000") }
    cli(%w[unlock])
    assert_equal :locked, consume(code(0, time: @t0 + 1), time: @t0 + 1).reason
  end

  def test_unknown_verb_prints_usage
    status, _out, err = cli(%w[frobnicate])
    assert_equal 1, status
    assert_match(/usage/, err)
  end

  # --- store: fencing, lockout, replay ---

  def test_a_code_is_accepted_once_and_the_replay_is_rejected
    enroll_totp(@home)
    assert_predicate consume(code), :ok?
    assert_equal :replay, consume(code).reason
  end

  def test_an_older_in_window_step_is_rejected_after_a_newer_one
    enroll_totp(@home)
    assert_predicate consume(code(1)), :ok?
    assert_equal :replay, consume(code(0)).reason
    assert_equal :replay, consume(code(-1)).reason
  end

  def test_the_next_step_is_accepted
    enroll_totp(@home)
    assert_predicate consume(code), :ok?
    later = @t0 + 30
    assert_predicate consume(code(0, time: later), time: later), :ok?
  end

  def test_malformed_and_wrong_codes_are_rejected_and_counted
    enroll_totp(@home)
    assert_equal :malformed, consume("12ab56").reason
    assert_equal :malformed, consume("").reason
    assert_equal :invalid, consume(code == "000000" ? "000001" : "000000").reason
    assert_equal 3, @store.status(now: @t0)[:failures]
  end

  def test_five_failures_lock_for_15_minutes_then_double
    enroll_totp(@home)
    5.times { consume("000000") }
    outcome = consume(code)
    assert_equal :locked, outcome.reason
    assert_equal @t0.utc + 900, outcome.locked_until
    later = @t0 + 901
    5.times { consume("000000", time: later) }
    assert_equal later.utc + 1800, consume(code(0, time: later), time: later).locked_until
  end

  def test_a_lockout_is_capped_at_24_hours
    enroll_totp(@home)
    state = JSON.parse(File.read(@store.path("totp_state.json")))
    state["lockouts"] = 20
    File.write(@store.path("totp_state.json"), JSON.generate(state))
    5.times { consume("000000") }
    assert_equal @t0.utc + 86_400, consume(code).locked_until
  end

  def test_a_success_resets_the_failure_count
    enroll_totp(@home)
    4.times { consume("000000") }
    assert_predicate consume(code), :ok?
    assert_equal 0, @store.status(now: @t0)[:failures]
  end

  def test_consume_raises_when_not_enrolled
    assert_raises(ApprovalConsole::LocalStore::NotEnrolled) { consume("123456") }
  end

  def test_a_corrupt_or_missing_state_file_fails_closed
    enroll_totp(@home)
    assert_predicate consume(code), :ok?
    File.write(@store.path("totp_state.json"), "{not json")
    assert_equal :error, consume(code(0, time: @t0 + 30), time: @t0 + 30).reason
    File.delete(@store.path("totp_state.json"))
    assert_equal :error, consume(code(0, time: @t0 + 60), time: @t0 + 60).reason
  end

  def test_parallel_processes_accept_one_code_at_most_once
    enroll_totp(@home)
    value = code
    script = <<~RUBY
      require "#{File.expand_path("../scripts/approval_console/local_store", __dir__)}"
      store = ApprovalConsole::LocalStore.new
      outcome = store.consume(ARGV[0], now: Time.at(#{@t0.to_i}))
      puts(outcome.ok? ? "ok" : outcome.reason)
    RUBY
    results = Array.new(6) { IO.popen({ "HOME" => @home }, [ RbConfig.ruby, "-e", script, value ], &:read).strip }
    assert_equal 1, results.count("ok"), results.inspect
    assert_equal 5, results.count("replay"), results.inspect
  end

  def test_parallel_failures_do_not_lose_an_increment
    enroll_totp(@home)
    script = <<~RUBY
      require "#{File.expand_path("../scripts/approval_console/local_store", __dir__)}"
      ApprovalConsole::LocalStore.new.consume("000000", now: Time.at(#{@t0.to_i}))
    RUBY
    4.times.map { Thread.new { system({ "HOME" => @home }, RbConfig.ruby, "-e", script) } }.each(&:join)
    assert_equal 4, @store.status(now: @t0)[:failures]
  end

  def test_the_sync_queue_is_written_only_once_a_console_is_configured
    enroll_totp(@home)
    consume(code, entry: { "type" => "step" })
    assert_equal 0, @store.pending.size
    config = JSON.parse(File.read(@store.path("console.json"))).merge("base_url" => "https://console.invalid")
    File.write(@store.path("console.json"), JSON.generate(config))
    later = @t0 + 30
    consume(code(0, time: later), time: later, entry: { "type" => "step" })
    assert_equal 1, @store.pending.size
    assert_equal Totp.step_for(later), @store.pending.first["step"]
  end

  def test_offline_bounds_refuse_new_approvals
    enroll_totp(@home)
    config = JSON.parse(File.read(@store.path("console.json"))).merge("base_url" => "https://console.invalid")
    File.write(@store.path("console.json"), JSON.generate(config))
    10.times do |i|
      time = @t0 + (30 * i)
      assert_predicate consume(code(0, time: time), time: time, entry: { "type" => "step" }), :ok?, i
    end
    time = @t0 + 300
    assert_equal :offline_limit, consume(code(0, time: time), time: time).reason
  end

  def test_offline_grace_expires_after_24_hours_without_a_sync
    enroll_totp(@home)
    config = JSON.parse(File.read(@store.path("console.json"))).merge("base_url" => "https://console.invalid")
    File.write(@store.path("console.json"), JSON.generate(config))
    assert_predicate consume(code, entry: { "type" => "step" }), :ok?
    later = @t0 + 86_401
    assert_equal :offline_limit, consume(code(0, time: later), time: later).reason
  end

  # --- host health and the terminal prompt ---

  def test_a_missing_store_is_degraded_and_refuses_high_risk_types
    report = ApprovalConsole::HostHealth.check(store: @store, home: @home)
    assert_predicate report, :degraded?
    %w[prod-op carve-out money].each do |type|
      assert_match(/degraded host/, ApprovalConsole::HostHealth.refusal(type, report))
    end
    assert_nil ApprovalConsole::HostHealth.refusal("step", report)
    assert_nil ApprovalConsole::HostHealth.refusal("override", report)
  end

  def test_a_wrong_mode_or_missing_guard_is_degraded
    enroll_totp(@home)
    assert_empty ApprovalConsole::HostHealth.check(store: @store, home: @home).reasons
    File.chmod(0o644, @store.path("totp_seed"))
    assert_match(/seed has mode 644/, ApprovalConsole::HostHealth.check(store: @store, home: @home).reasons.join)
    File.chmod(0o600, @store.path("totp_seed"))
    File.delete(File.join(@home, ApprovalConsole::HostHealth::GUARD))
    assert_match(/read guard is not installed/, ApprovalConsole::HostHealth.check(store: @store, home: @home).reasons.join)
  end

  def test_preflight_names_the_enroll_snippet_and_refuses_high_risk_on_a_degraded_host
    assert_match(/totp-enroll/, ApprovalConsole::TerminalPrompt.preflight("step", store: @store, home: @home))
    enroll_totp(@home)
    assert_nil ApprovalConsole::TerminalPrompt.preflight("step", store: @store, home: @home)
    File.chmod(0o755, @store.dir)
    assert_match(/degraded host/, ApprovalConsole::TerminalPrompt.preflight("money", store: @store, home: @home))
    assert_nil ApprovalConsole::TerminalPrompt.preflight("step", store: @store, home: @home)
  end

  def test_prompt_returns_a_terminal_proof_with_a_null_receipt
    enroll_totp(@home)
    attrs = { "type" => "override", "repo" => "repo:x/y", "sha" => "a" * 40, "profile" => nil, "reason" => "why" }
    result = ApprovalConsole::TerminalPrompt.approve(attrs, stdin: StringIO.new("#{code}\n"), stdout: StringIO.new,
                                                            store: @store, now: @t0)
    assert_predicate result, :ok?
    assert_equal "totp-terminal", result.proof["kind"]
    assert_nil result.proof["receipt"]
    assert_equal Totp.step_for(@t0), result.proof["totp_step"]
    assert_equal "why", ApprovalConsole::Canonical.parse(result.proof["body"])["reason"]
  end

  def test_prompt_samples_the_clock_after_the_code_is_typed
    enroll_totp(@home)
    attrs = { "type" => "override", "repo" => "repo:x/y", "sha" => "a" * 40, "profile" => nil, "reason" => "why" }
    slow = Object.new
    code_text = code(0, time: Time.now)
    slow.define_singleton_method(:gets) { sleep 0.01; "#{code_text}\n" }
    result = ApprovalConsole::TerminalPrompt.approve(attrs, stdin: slow, stdout: StringIO.new, store: @store)
    assert_predicate result, :ok?
    assert_operator result.proof["totp_step"], :>=, Totp.step_for(Time.now) - 1
  end

  def test_prompt_rejects_a_wrong_replayed_and_missing_code
    enroll_totp(@home)
    attrs = { "type" => "override", "repo" => "repo:x/y", "sha" => "a" * 40, "profile" => nil, "reason" => "why" }
    try = ->(text) { ApprovalConsole::TerminalPrompt.approve(attrs, stdin: StringIO.new(text), stdout: StringIO.new, store: @store, now: @t0) }
    assert_match(/not valid/, try.call("000000\n").error) unless code == "000000"
    assert_match(/6 digits/, try.call("\n").error)
    assert_match(/6 digits/, try.call("").error)
    assert_predicate try.call("#{code}\n"), :ok?
    assert_match(/already used/, try.call("#{code}\n").error)
  end

  def test_prompt_without_a_seed_returns_the_enroll_snippet
    attrs = { "type" => "override", "repo" => "repo:x/y", "sha" => "a" * 40, "profile" => nil, "reason" => "why" }
    result = ApprovalConsole::TerminalPrompt.approve(attrs, stdin: StringIO.new("123456\n"), stdout: StringIO.new, store: @store)
    assert_match(/totp-enroll/, result.error)
  end
end
