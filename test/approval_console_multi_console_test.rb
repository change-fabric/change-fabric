# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
require "openssl"
require_relative "support/totp_enrollment"
require_relative "../scripts/approval_console"

# One machine enrolled on several self-hosted consoles: per-console pins and
# queues, routing by the repo's authoritative approval_pins.rp_id, and the
# in-place move of a single-console enrollment.
class ApprovalConsoleMultiConsoleTest < Minitest::Test
  include TotpEnrollment

  ALPHA = "alpha1234.lambda-url.us-east-1.on.aws"
  BETA = "beta5678.lambda-url.us-east-2.on.aws"
  Authority = Struct.new(:policy, :policy_sha)
  Policy = Struct.new(:approval_pins)
  NoTty = Struct.new(:tty?)

  def setup
    @home = File.realpath(Dir.mktmpdir)
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
    @store = enroll_totp(@home)
    @keys = { ALPHA => OpenSSL::PKey::EC.generate("prime256v1"), BETA => OpenSSL::PKey::EC.generate("prime256v1") }
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def pin(rp_id, store: @store)
    store.pin!(base_url: "https://#{rp_id}/", rp_id: rp_id, credentials: { "cred-#{rp_id[0, 5]}" => "cose" },
               receipt_public_key: @keys[rp_id].public_to_pem, receipt_key_id: "arn:aws:kms:test:key/#{rp_id[0, 5]}")
  end

  def expect_for(rp_id) = { "rp_id" => rp_id, "receipt_key_fingerprint" => ApprovalConsole::LocalStore.key_fingerprint(@keys[rp_id].public_to_pem) }

  def authority(rp_id) = Authority.new(Policy.new(rp_id && expect_for(rp_id)), "c" * 40)

  def cli(argv, auth:, client: nil)
    out = StringIO.new
    err = StringIO.new
    status = ApprovalConsoleCli.run(argv, stdin: NoTty.new(false), stdout: out, stderr: err, env: { "CLAUDECODE" => "1" },
                                          store: ApprovalConsole::LocalStore.new, tty_open: -> { }, parents: -> { [ "claude" ] },
                                          io: { authority: auth, client: client })
    [ status, out.string, err.string ]
  end

  def request(auth, client)
    cli([ "request", "--type", "release", "--tag", "v1", "--sha", "a" * 40, "--repo", @home, "--no-wait" ], auth: auth, client: client)
  end

  def test_two_consoles_live_side_by_side_on_one_machine
    pin(ALPHA)
    pin(BETA)
    assert_equal [ ALPHA, BETA ], @store.consoles
    assert_equal BETA, @store.default_console, "the most recent enroll is the default"
    assert_equal "https://#{BETA}/", @store.base_url
    alpha = @store.for_console(ALPHA)
    assert_equal "https://#{ALPHA}/", alpha.base_url
    assert_equal ALPHA, alpha.pins["rp_id"]
    assert_equal BETA, @store.pins["rp_id"]
    assert_equal @store.machine_id, alpha.machine_id, "one machine id across consoles"
    assert_equal @store.seed, alpha.seed, "one TOTP seed across consoles"
    pin(ALPHA)
    assert_equal 2, @store.consoles.size, "re-enrolling a console replaces nothing else"
    assert_equal ALPHA, @store.default_console
  end

  def test_an_unbound_store_reads_the_console_the_authoritative_pins_name
    pin(ALPHA)
    pin(BETA)
    assert_equal ALPHA, @store.pins(expect: expect_for(ALPHA))["rp_id"]
    assert_equal BETA, @store.pins(expect: expect_for(BETA))["rp_id"]
  end

  def test_a_bound_store_names_both_rp_ids_on_a_mismatch
    pin(ALPHA)
    pin(BETA)
    error = assert_raises(ApprovalConsole::LocalStore::PinMismatch) { @store.for_console(BETA).pins(expect: expect_for(ALPHA)) }
    assert_includes error.message, BETA
    assert_includes error.message, ALPHA
  end

  def test_an_unenrolled_pin_names_it_and_the_enrolled_consoles
    pin(BETA)
    error = assert_raises(ApprovalConsole::LocalStore::PinMismatch) { @store.pins(expect: expect_for(ALPHA)) }
    assert_includes error.message, ALPHA
    assert_includes error.message, "enrolled: #{BETA}"
  end

  def test_the_receipt_key_is_still_checked_per_console
    pin(ALPHA)
    pin(BETA)
    forged = expect_for(ALPHA).merge("receipt_key_fingerprint" => expect_for(BETA)["receipt_key_fingerprint"])
    assert_raises(ApprovalConsole::LocalStore::PinMismatch) { @store.pins(expect: forged) }
  end

  def test_a_policy_rp_id_that_is_not_a_dns_name_never_becomes_a_path
    pin(BETA)
    [ "../#{BETA}", "#{BETA}/../x", "..", "" ].each do |rp|
      assert_raises(ApprovalConsole::LocalStore::PinMismatch, rp) { @store.pins(expect: { "rp_id" => rp, "receipt_key_fingerprint" => "x" }) }
      refute ApprovalConsole::LocalStore.rp_id?(rp)
    end
  end

  def test_offline_queues_are_per_console_and_the_replay_fence_is_per_machine
    pin(ALPHA)
    pin(BETA)
    t0 = Time.at(1_800_000_000)
    alpha = @store.for_console(ALPHA)
    assert_predicate alpha.consume(totp_now(@store, time: t0), now: t0, entry: { "type" => "step" }), :ok?
    assert_equal 1, alpha.pending.size
    assert_equal 0, @store.for_console(BETA).pending.size
    assert_equal :replay, @store.for_console(BETA).consume(totp_now(@store, time: t0), now: t0).reason
  end

  # Writes the pre-multi-console layout for BETA by hand; returns the machine config.
  def write_single_console_layout(dir)
    config = JSON.parse(File.read(File.join(dir, "console.json")))
    File.write(File.join(dir, "console.json"), JSON.generate(config.merge("base_url" => "https://#{BETA}/", "rp_id" => BETA)))
    File.write(File.join(dir, "credentials.json"), JSON.generate("rp_id" => BETA, "credentials" => { "c1" => "cose" },
                                                                  "receipt_public_key" => @keys[BETA].public_to_pem, "receipt_key_id" => "k"))
    File.write(File.join(dir, "pending_sync.jsonl"), "#{JSON.generate('body_sha256' => 'x', 'step' => 1)}\n")
    state = JSON.parse(File.read(File.join(dir, "totp_state.json"))).merge("last_sync" => "2027-01-15T00:00:00Z")
    File.write(File.join(dir, "totp_state.json"), JSON.generate(state))
    config
  end

  def snapshot(dir) = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).reject { |f| f.end_with?(".") || f.end_with?(".lock") }
                         .sort.to_h { |f| [ f, File.file?(f) ? File.binread(f) : :dir ] }

  # Every read path, run against an unmigrated single-console store, leaves
  # every file byte-identical, so released code sharing the store keeps working.
  def test_a_read_never_rewrites_the_store
    dir = @store.dir
    write_single_console_layout(dir)
    before = snapshot(dir)
    store = ApprovalConsole::LocalStore.new
    assert_equal [ BETA ], store.consoles
    assert_equal BETA, store.default_console
    assert_equal "https://#{BETA}/", store.base_url
    assert_predicate store, :console_configured?
    assert_equal BETA, store.pins(expect: expect_for(BETA))["rp_id"]
    assert_equal 1, store.pending.size
    store.status
    store.machine_id
    store.for_console(BETA).pins
    assert_raises(ApprovalConsole::LocalStore::PinMismatch) { store.pins(expect: expect_for(ALPHA)) }
    cli([ "status" ], auth: authority(BETA))
    cli([ "verify", "a" * 40, "--repo", @home ], auth: authority(BETA))
    assert_equal before, snapshot(dir)
  end

  def test_offline_approvals_on_an_unmigrated_store_stay_where_released_code_reads_them
    dir = @store.dir
    write_single_console_layout(dir)
    t0 = Time.at(1_800_000_000)
    assert_predicate @store.consume(totp_now(@store, time: t0), now: t0, entry: { "type" => "step" }), :ok?
    assert_equal 2, File.readlines(File.join(dir, "pending_sync.jsonl")).size
    @store.observe_step(1, now: t0)
    assert_equal t0.utc.iso8601, JSON.parse(File.read(File.join(dir, "totp_state.json")))["last_sync"]
    refute File.exist?(File.join(dir, "consoles"))
  end

  # Remote.submit saves the request after posting; on an unmigrated store that
  # save must not raise, or the phone link is never printed.
  def test_saving_a_request_on_an_unmigrated_store_records_its_console
    dir = @store.dir
    write_single_console_layout(dir)
    id = "0f0e0d0c-0b0a-4908-8706-050403020100"
    ApprovalConsole::LocalStore.new.save_request(id, "{}")
    assert_equal BETA, File.read(File.join(dir, "requests", "#{id}.console"))
    refute File.exist?(File.join(dir, "consoles"))
  end

  # Interrupted after console.json was rewritten but before credentials.json
  # was removed: the retry must keep the console URL the first pass moved.
  def test_a_retried_migration_keeps_the_moved_console_url
    dir = @store.dir
    write_single_console_layout(dir)
    creds = File.read(File.join(dir, "credentials.json"))
    store = ApprovalConsole::LocalStore.new
    store.migrate!
    File.write(File.join(dir, "credentials.json"), creds)
    assert_equal BETA, store.migrate!
    assert_equal "https://#{BETA}/", store.base_url
    assert_predicate store, :console_configured?
  end

  def test_migration_waits_for_the_totp_lock
    dir = @store.dir
    write_single_console_layout(dir)
    File.open(File.join(dir, "totp.lock"), File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)
      migration = Thread.new { ApprovalConsole::LocalStore.new.migrate! }
      refute migration.join(0.3), "migrate! must block while the TOTP lock is held"
      held.flock(File::LOCK_UN)
      assert_equal BETA, migration.value
    end
  end

  def test_migrate_needs_a_human_and_enroll_migrates
    write_single_console_layout(@store.dir)
    status, _out, err = cli([ "migrate" ], auth: nil)
    assert_equal 2, status
    assert_match(/real terminal/, err)
    refute File.exist?(File.join(@store.dir, "consoles"))
  end

  def test_a_single_console_enrollment_moves_in_place
    dir = @store.dir
    config = write_single_console_layout(dir)
    store = ApprovalConsole::LocalStore.new
    assert_equal BETA, store.migrate!
    assert_nil store.migrate!, "a second migrate finds nothing to move"
    assert_equal [ BETA ], store.consoles
    assert_equal BETA, store.default_console
    assert_equal "https://#{BETA}/", store.base_url
    assert_equal config["machine_id"], store.machine_id
    assert_equal({ "c1" => "cose" }, store.pins(expect: expect_for(BETA))["credentials"])
    assert_equal 1, store.pending.size
    assert_equal "2027-01-15T00:00:00Z", JSON.parse(File.read(File.join(dir, "consoles", BETA, "sync_state.json")))["last_sync"]
    refute File.exist?(File.join(dir, "credentials.json"))
    refute File.exist?(File.join(dir, "pending_sync.jsonl"))
    refute JSON.parse(File.read(File.join(dir, "console.json"))).key?("base_url")
    assert_equal 0o700, File.stat(File.join(dir, "consoles", BETA)).mode & 0o777
    pin(ALPHA, store: store)
    assert_equal [ ALPHA, BETA ], store.consoles, "a second enroll after the move adds a console"
  end

  def test_status_lists_every_console_and_marks_the_repo_one
    pin(ALPHA)
    pin(BETA)
    status, out, = cli([ "status" ], auth: authority(ALPHA))
    assert_equal 0, status
    assert_match(/consoles: 2/, out)
    assert_match(/#{Regexp.escape(ALPHA)} .*\(this repo\)/, out)
    assert_match(/#{Regexp.escape(BETA)} .*\(default\)/, out)
    assert_match(%r{console: https://#{Regexp.escape(ALPHA)}/}, out)
  end

  def test_a_repo_with_no_pins_uses_the_default_console
    pin(ALPHA)
    pin(BETA)
    _status, out, = cli([ "status" ], auth: authority(nil))
    assert_match(%r{console: https://#{Regexp.escape(BETA)}/}, out)
  end

  def test_a_request_is_sent_to_the_repo_console_and_remembers_it
    pin(ALPHA)
    pin(BETA)
    client = Object.new
    client.define_singleton_method(:create_request) { |_body| { "url" => "https://#{ALPHA}/r/x" } }
    status, out, err = request(authority(ALPHA), client)
    assert_equal 0, status, err
    assert_equal ALPHA, @store.request_console(JSON.parse(out)["request_id"])
  end

  def test_a_repo_pinning_an_unenrolled_console_is_refused_before_asking
    pin(BETA)
    posted = []
    client = Object.new
    client.define_singleton_method(:create_request) { |body| posted << body and { "url" => "x" } }
    status, _out, err = request(authority(ALPHA), client)
    assert_equal 2, status
    assert_empty posted, "nothing reaches any console, so no phone approval is wasted"
    assert_match(/#{Regexp.escape(ALPHA)}" is not enrolled on this machine \(enrolled: #{Regexp.escape(BETA)}\)/, err)
    assert_includes err, "enroll --url https://#{ALPHA}/"
  end
end
