# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require_relative "support/phone_console"
require_relative "../scripts/cf_run_approved"
require_relative "../scripts/approval_console/recorder"

# cf_run_approved.rb against the real console in process: the phone approves a
# run-script body, the Recorder stores it, the runner re-checks everything and
# consumes the receipt on the console before the script runs.
class CfRunApprovedTest < Minitest::Test
  include PhoneConsole

  REPO = "repo:github.com/acme/widgets"

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    @queue = File.join(@home, ".claude", "cf", "manual", "queue")
    FileUtils.mkdir_p(@queue)
    @repo = File.join(@home, "checkout")
    FileUtils.mkdir_p(@repo)
    git("init", "-q", "-b", "main")
    git("remote", "add", "origin", "https://github.com/acme/widgets.git")
    File.write(File.join(@repo, "a.txt"), "x")
    git("add", "a.txt")
    git("-c", "user.email=t@t.test", "-c", "user.name=t", "commit", "-q", "-m", "c")
    @sha = git("rev-parse", "HEAD").strip
    start_phone_console
    @script = File.join(@queue, "0001-hello.sh")
    File.write(@script, "echo hello-from-script\necho \"commit=$CF_APPROVED_COMMIT\"\ntest ! -t 0\n")
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @repo, *args)
    raise out unless status.success?

    out
  end

  def attrs(path: @script, account: nil, sha: @sha, text: File.read(@script), profile: nil)
    { "type" => "run-script", "repo" => REPO, "sha" => sha, "profile" => profile, "title" => "say hello", "account" => account,
      "script_sha256" => Digest::SHA256.hexdigest(text.b), "script_path" => path, "script_text" => text }
  end

  def approve(**opts)
    attributes = attrs(**opts)
    proof = phone_proof(attributes)
    result = ApprovalConsole::Recorder.new(authority: authority, store: @store, clock: -> { @now }, recorded_by: "t")
                                      .record(proof, expected: ApprovalConsole::Remote.expected(attributes, mid))
    assert_predicate result, :ok?, result.error
    proof
  end

  def runner(at: @now, account: nil, run: nil, profile: nil, env: {})
    @out = StringIO.new
    @err = StringIO.new
    opts = { home: @home, store: @store, client: client, authority: authority, clock: -> { at }, out: @out, err: @err }
    @profiles = []
    opts[:account] = ->(used) { @profiles << used; account } if account
    opts[:profile] = profile
    opts[:env] = env
    opts[:runner] = run if run
    CfRunApproved.new(**opts)
  end

  def go(**opts) = runner(**opts).run(@script, repo: @repo)

  def test_a_valid_run_streams_the_output_without_a_tty_and_moves_the_script_to_done
    approve
    assert_equal 0, go
    assert_includes @out.string, "hello-from-script"
    assert_includes @out.string, "commit=#{@sha}"
    refute_path_exists @script
    assert_path_exists File.join(@queue, "done", "0001-hello.sh")
  end

  def test_a_tampered_script_is_refused_and_nothing_runs
    approve
    File.write(@script, File.read(@script) + "echo pwned\n")
    assert_equal 1, go
    assert_match(/no phone-approved run is recorded for this exact script/, @err.string)
    refute_includes @out.string, "hello-from-script"
    assert_path_exists @script
  end

  def test_a_receipt_signed_for_different_text_under_the_same_hash_key_is_refused
    approve
    other = attrs(text: "echo different\n")
    ChangeRunScriptStore.new.record(repo: REPO, script_sha256: Digest::SHA256.hexdigest(File.read(@script).b), sha: @sha,
                                    proof: phone_proof(other), policy_sha: POLICY_SHA, recorded_by: "t")
    assert_equal 1, go
    assert_match(/receipt is refused/, @err.string)
  end

  def test_a_reused_receipt_is_refused_even_after_a_failed_run
    approve
    assert_equal 3, go(run: ->(*_) { 3 })
    assert_match(/receipt is consumed/, @err.string)
    assert_path_exists @script
    assert_equal 1, go
    assert_match(/already used/, @err.string)
  end

  def test_the_console_refuses_a_second_consume_when_the_local_ledger_is_gone
    approve
    assert_equal 0, go
    FileUtils.rm_rf(File.join(@home, ".claude", "cf", "change", "run-ledger"))
    File.write(@script, File.read(File.join(@queue, "done", "0001-hello.sh")))
    assert_equal 1, go
    assert_match(/console refused to consume the receipt \(consumed\)/, @err.string)
  end

  def test_a_script_swapped_after_verification_still_runs_the_approved_bytes
    approve
    swapper = Object.new
    swapper.define_singleton_method(:consume) do |id|
      File.write(@script, "echo pwned\n")
      @inner.consume(id)
    end
    swapper.instance_variable_set(:@script, @script)
    swapper.instance_variable_set(:@inner, client)
    @out = StringIO.new
    @err = StringIO.new
    code = CfRunApproved.new(home: @home, store: @store, client: swapper, authority: authority, clock: -> { @now }, out: @out, err: @err)
                        .run(@script, repo: @repo)
    assert_equal 0, code
    assert_includes @out.string, "hello-from-script"
    refute_includes @out.string, "pwned"
    assert_match(/changed after it was approved; left in the queue/, @err.string)
    assert_path_exists @script
  end

  def test_a_script_that_reads_stdin_sees_eof_instead_of_hanging
    File.write(@script, "if read -r -t 5 line; then echo got-data; else echo status=$?; fi\n")
    approve
    assert_equal 0, go
    assert_includes @out.string, "status=1"
  end

  def test_a_wrong_account_is_refused
    approve(account: "123456789012")
    assert_equal 1, go(account: "999999999999")
    assert_match(/AWS account 123456789012 but the current account is "999999999999"/, @err.string)
    refute_includes @out.string, "hello-from-script"
  end

  def test_the_right_account_runs
    approve(account: "123456789012")
    assert_equal 0, go(account: "123456789012")
  end

  def test_the_account_is_asked_of_the_flag_profile_first
    approve(account: "123456789012", profile: "from-receipt")
    assert_equal 0, go(account: "123456789012", profile: "from-flag", env: { "AWS_PROFILE" => "from-env" })
    assert_equal [ "from-flag" ], @profiles
  end

  def test_the_account_falls_back_to_the_receipt_profile_then_aws_profile
    approve(account: "123456789012", profile: "from-receipt")
    assert_equal 0, go(account: "123456789012", env: { "AWS_PROFILE" => "from-env" })
    assert_equal [ "from-receipt" ], @profiles
  end

  def test_the_account_falls_back_to_aws_profile_without_a_receipt_profile
    approve(account: "123456789012")
    assert_equal 0, go(account: "123456789012", env: { "AWS_PROFILE" => "from-env" })
    assert_equal [ "from-env" ], @profiles
  end

  def test_an_unresolvable_identity_names_the_profile_flag
    approve(account: "123456789012")
    runner_obj = runner
    runner_obj.define_singleton_method(:current_account) { |_profile| nil }
    assert_equal 1, runner_obj.run(@script, repo: @repo)
    assert_match(/no AWS identity could be resolved \(profile: none\); pass --profile NAME/, @err.string)
    refute_includes @out.string, "hello-from-script"
  end

  def test_the_script_runs_as_the_verified_profile_with_ambient_credentials_removed
    File.write(@script, "echo \"profile=$AWS_PROFILE key=${AWS_ACCESS_KEY_ID:-none} secret=${AWS_SECRET_ACCESS_KEY:-none} " \
                        "token=${AWS_SESSION_TOKEN:-none} default=${AWS_DEFAULT_PROFILE:-none}\"\n")
    approve(account: "123456789012", profile: "from-receipt")
    ambient = { "AWS_ACCESS_KEY_ID" => "k", "AWS_SECRET_ACCESS_KEY" => "s", "AWS_SESSION_TOKEN" => "t", "AWS_DEFAULT_PROFILE" => "other",
                "AWS_PROFILE" => "other" }
    saved = ambient.keys.to_h { |name| [ name, ENV[name] ] }
    ambient.each { |name, value| ENV[name] = value }
    begin
      assert_equal 0, go(account: "123456789012", profile: "from-flag")
    ensure
      saved.each { |name, value| ENV[name] = value }
    end
    assert_includes @out.string, "profile=from-flag key=none secret=none token=none default=none"
  end

  def test_an_expired_receipt_is_refused
    approve
    assert_equal 1, go(at: @now + 901)
    assert_match(/15 minutes old or older/, @err.string)
    assert_path_exists @script
  end

  def test_a_different_head_is_refused
    approve(sha: "f" * 40)
    assert_equal 1, go
    assert_match(/no phone-approved run is recorded/, @err.string)
  end

  def test_an_unreachable_console_refuses_and_releases_the_ledger_for_a_retry
    approve
    down = Object.new
    def down.consume(_id) = raise(ApprovalConsole::Client::Unreachable, "timeout")
    @out = StringIO.new
    @err = StringIO.new
    code = CfRunApproved.new(home: @home, store: @store, client: down, authority: authority, clock: -> { @now }, out: @out, err: @err)
                        .run(@script, repo: @repo)
    assert_equal 1, code
    assert_match(/console is unreachable \(timeout\); nothing ran/, @err.string)
    assert_equal 0, go
  end

  def test_a_script_outside_the_queue_is_refused
    outside = File.join(@home, "elsewhere.sh")
    File.write(outside, "echo hi\n")
    assert_equal 1, runner.run(outside, repo: @repo)
    assert_match(/is not directly in/, @err.string)
  end

  def autopiloted(id: "e" * 64, env: {}, profile: nil, run: nil)
    @asked = []
    @out = StringIO.new
    @err = StringIO.new
    waiver = ->(root, detail, text) { @asked << [ root, detail, text ]; id }
    opts = { home: @home, store: @store, client: client, authority: authority, clock: -> { @now }, out: @out, err: @err,
             autopilot: waiver, env: env, profile: profile }
    opts[:runner] = run if run
    CfRunApproved.new(**opts)
  end

  def test_with_no_recorded_approval_an_active_autopilot_runs_the_script_and_logs_it
    assert_equal 0, autopiloted.run(@script, repo: @repo)
    assert_includes @out.string, "hello-from-script"
    assert_equal [ [ @repo, "run 0001-hello.sh at #{@sha[0, 12]}", File.read(File.join(@queue, "done", "0001-hello.sh")) ] ], @asked.map { |root, detail, text| [ File.realpath(root), detail, text ] }
    rows = Dir.children(File.join(@home, ".claude", "cf", "change", "run-ledger"))
    assert_equal 1, rows.size
    assert_match(/\Aautopilot-#{'e' * 16}-/, rows.first)
    assert_path_exists File.join(@queue, "done", "0001-hello.sh")
  end

  def test_the_autopilot_run_passes_its_id_in_place_of_a_request_id_and_pins_one_profile
    seen = nil
    run = ->(_path, _root, _sha, request) { seen = request; 0 }
    runner = autopiloted(env: { "AWS_PROFILE" => "only-this" }, run: run)
    runner.run(@script, repo: @repo)
    assert_equal "autopilot:#{'e' * 64}", seen
    assert_equal({ "AWS_PROFILE" => "only-this", "AWS_ACCESS_KEY_ID" => nil, "AWS_SECRET_ACCESS_KEY" => nil,
                   "AWS_SESSION_TOKEN" => nil, "AWS_DEFAULT_PROFILE" => nil }, runner.send(:aws_identity_env))
  end

  def test_with_no_approval_and_no_autopilot_it_still_refuses
    @out = StringIO.new
    @err = StringIO.new
    refuser = CfRunApproved.new(home: @home, store: @store, client: client, authority: authority, clock: -> { @now }, out: @out, err: @err,
                                autopilot: ->(*) { nil })
    assert_equal 1, refuser.run(@script, repo: @repo)
    assert_match(/no phone-approved run is recorded for this exact script/, @err.string)
    assert_path_exists @script
    refute_includes @out.string, "hello-from-script"
  end

  def test_the_default_waiver_fails_closed_with_no_autopilot_on_disk
    assert_equal 1, go
    assert_match(/no phone-approved run is recorded/, @err.string)
  end

  def test_a_recorded_approval_is_used_before_the_autopilot
    approve
    runner = autopiloted
    assert_equal 0, runner.run(@script, repo: @repo)
    assert_empty @asked
  end
end
