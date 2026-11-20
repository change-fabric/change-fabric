# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "../scripts/resource_probe"

class ResourceProbeTest < Minitest::Test
  RP = ResourceProbe

  # Returns scripted run results; never starts a process.
  class FakeRunner
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def run(argv, root:, cwd:, env: {}, docker: nil)
      @calls << { argv: argv, root: root, cwd: cwd, env: env, docker: docker }
      @results.length > 1 ? @results.shift : @results.first
    end
  end

  def ok(rss: 500, disk: 1.0, dmem: 0, ddisk: 0.0, samples: 3) =
    { exit: 0, signal: nil, peak_rss_mb: rss, disk_delta_gb: disk, docker_mem_peak_mb: dmem, docker_disk_delta_gb: ddisk, samples: samples }

  def setup
    @home = File.realpath(Dir.mktmpdir("probe-home"))
    @root = File.realpath(Dir.mktmpdir("probe-repo"))
    @ident = CfProjectIdentity.for(@root)
    @store = RP::Store.new(slug: @ident.slug, home: @home)
    @clock = 1_000_000
  end

  def teardown
    FileUtils.rm_rf([ @home, @root ])
  end

  def probe_with(runner) = RP::Probe.new(root: @root, store: @store, runner: runner, now: -> { @clock })

  def test_probe_writes_the_exact_profile_format_the_gate_reads
    probe_with(FakeRunner.new(ok)).probe("rake_test", %w[bundle exec rake test], cwd: @root)
    entry = ResourceGate.load_profile(@root, home: @home)["rake_test"]
    assert_equal 500, entry["peak_rss_mb"]
    assert_equal 1.0, entry["disk_delta_gb"]
    assert_equal %w[bundle exec rake test], entry["command"]
    assert_equal ".", entry["cwd"]
    assert entry["lower_bound"]
    assert_equal 1_000_000, entry["updated_at_epoch"]
    assert_equal "ops", JSON.parse(File.read(@store.path)).keys.last
  end

  def test_gate_treats_fresh_profile_op_as_non_provisional_and_changed_fingerprint_as_stale
    probe_with(FakeRunner.new(ok)).probe("build", %w[make], cwd: @root)
    assert_nil ResourceGate.load_profile(@root, home: @home)["build"]["stale"]
    File.write(File.join(@root, "Gemfile.lock"), "changed")
    assert_equal true, ResourceGate.load_profile(@root, home: @home)["build"]["stale"]
  end

  def test_fingerprint_tracks_lockfiles_dockerfiles_and_change_block_only
    base = ResourceFingerprint.compute(@root)
    File.write(File.join(@root, "README.md"), "x")
    assert_equal base, ResourceFingerprint.compute(@root)
    File.write(File.join(@root, "Dockerfile"), "FROM x")
    refute_equal base, ResourceFingerprint.compute(@root)
    one = ResourceFingerprint.compute(@root)
    File.write(File.join(@root, "CHANGE.md"), "title\nboot:\n  up: a\nlanes:\n  k6: {}\nother: 1\n")
    two = ResourceFingerprint.compute(@root)
    refute_equal one, two
    File.write(File.join(@root, "CHANGE.md"), "title changed\nboot:\n  up: a\nlanes:\n  k6: {}\nother: 2\n")
    assert_equal two, ResourceFingerprint.compute(@root)
    File.write(File.join(@root, "CHANGE.md"), "boot:\n  up: b\nlanes:\n  k6: {}\n")
    refute_equal two, ResourceFingerprint.compute(@root)
  end

  def test_ops_keep_independent_fingerprint_and_timestamp
    probe_with(FakeRunner.new(ok)).probe("a", %w[true], cwd: @root)
    File.write(File.join(@root, "package-lock.json"), "{}")
    @clock += 100
    probe_with(FakeRunner.new(ok)).probe("b", %w[true], cwd: @root)
    ops = @store.ops
    refute_equal ops["a"]["fingerprint"], ops["b"]["fingerprint"]
    assert_equal 1_000_000, ops["a"]["updated_at_epoch"]
    assert_equal 1_000_100, ops["b"]["updated_at_epoch"]
  end

  def test_peak_more_than_25_percent_over_raises_immediately
    probe_with(FakeRunner.new(ok(rss: 1000))).probe("t", %w[true], cwd: @root)
    probe_with(FakeRunner.new(ok(rss: 1300))).probe("t", %w[true], cwd: @root)
    assert_equal 1300, @store.ops["t"]["peak_rss_mb"]
  end

  def test_lower_or_slightly_higher_peaks_decay_slowly
    probe_with(FakeRunner.new(ok(rss: 1000))).probe("t", %w[true], cwd: @root)
    probe_with(FakeRunner.new(ok(rss: 100))).probe("t", %w[true], cwd: @root)
    assert_equal 900, @store.ops["t"]["peak_rss_mb"]
    probe_with(FakeRunner.new(ok(rss: 1100))).probe("t", %w[true], cwd: @root)
    assert_equal 1100, @store.ops["t"]["peak_rss_mb"], "within 25% takes the larger of new and decayed"
    assert_equal 1250.0, RP::Drift.blend(1000.0, 1250.0)
    assert_equal 1251.0, RP::Drift.blend(1000.0, 1251.0)
  end

  def test_drift_applies_to_docker_and_disk_fields
    probe_with(FakeRunner.new(ok(dmem: 1000, ddisk: 2.0, disk: 4.0))).probe("d", %w[docker build .], cwd: @root)
    probe_with(FakeRunner.new(ok(dmem: 2000, ddisk: 0.0, disk: 0.0))).probe("d", %w[docker build .], cwd: @root)
    e = @store.ops["d"]
    assert_equal 2000, e["docker_mem_peak_mb"]
    assert_equal 1.8, e["docker_disk_delta_gb"]
    assert_equal 3.6, e["disk_delta_gb"]
  end

  def test_failed_and_signaled_runs_record_nothing_and_pass_status_through
    failed = probe_with(FakeRunner.new(ok.merge(exit: 3))).probe("t", %w[false], cwd: @root)
    assert_equal 3, failed.exit_code
    killed = probe_with(FakeRunner.new(ok.merge(exit: nil, signal: "TERM"))).probe("t", %w[x], cwd: @root)
    assert_equal "TERM", killed.signal
    assert_empty @store.ops
  end

  def test_staleness_by_ttl_and_fingerprint
    entry = { "fingerprint" => "abc", "updated_at_epoch" => 1000 }
    ttl = 30 * 86_400
    assert_nil RP.staleness(entry, "abc", now: 1000 + ttl, ttl_seconds: ttl)
    assert_equal "older than TTL", RP.staleness(entry, "abc", now: 1001 + ttl, ttl_seconds: ttl)
    assert_equal "fingerprint changed", RP.staleness(entry, "zzz", now: 1000, ttl_seconds: ttl)
  end

  def test_stale_op_gets_the_stale_headroom_in_the_gate
    probe_with(FakeRunner.new(ok(rss: 4000))).probe("t", %w[true], cwd: @root)
    File.write(File.join(@root, "Gemfile.lock"), "new")
    entry = ResourceGate.load_profile(@root, home: @home)["t"]
    floors = ResourceGate::Floors.new(platform: "linux", repo_file: ResourceGate.defaults_file, user_file: nil, env: {})
    mem = Struct.new(:read).new({ available_mb: 20_000, total_mb: 16_000, pressure_normal: nil })
    disk = Struct.new(:free_gb_value) { def free_gb(_) = free_gb_value }.new(100.0)
    gate = ResourceGate::Gate.new(project: @root, floors: floors, mem: mem, disk: disk, profile: { "t" => entry }, now: Time.at(1_000_100), platform: "linux")
    result = gate.check(batches: [ [ { op: "t", count: 1 } ] ])
    assert_equal 6000, result.json[:need][:ram_mb], "stale headroom 1.5"
    refute result.json[:provisional]
    mixed = gate.check(batches: [ [ { op: "t", count: 1 }, { op: "unmeasured", count: 1 } ] ])
    assert mixed.json[:provisional]
  end

  def test_fresh_op_gets_fresh_headroom_and_ttl_expiry_makes_it_stale
    probe_with(FakeRunner.new(ok(rss: 4000))).probe("t", %w[true], cwd: @root)
    entry = ResourceGate.load_profile(@root, home: @home)["t"]
    floors = ResourceGate::Floors.new(platform: "linux", repo_file: ResourceGate.defaults_file, user_file: nil, env: {})
    mem = Struct.new(:read).new({ available_mb: 20_000, total_mb: 16_000, pressure_normal: nil })
    disk = Struct.new(:v) { def free_gb(_) = v }.new(100.0)
    at = ->(t) { ResourceGate::Gate.new(project: @root, floors: floors, mem: mem, disk: disk, profile: { "t" => entry }, now: Time.at(t), platform: "linux") }
    batch = [ [ { op: "t", count: 1 } ] ]
    assert_equal 5000, at.call(1_000_100).check(batches: batch).json[:need][:ram_mb]
    assert_equal 6000, at.call(1_000_000 + (31 * 86_400)).check(batches: batch).json[:need][:ram_mb]
  end

  def test_storage_rule_strips_absolute_paths_env_values_and_secrets
    secret = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
    argv = [ "#{@root}/bin/run", "--config=#{@root}/conf/a.yml", "/etc/passwd", "~/private/file", "API_KEY=hunter2hunter2",
             "--token", "tok-value-plain", "--password=abc", secret, "--ok=1", "plain" ]
    sub = File.join(@root, "sub")
    FileUtils.mkdir_p(sub)
    probe_with(FakeRunner.new(ok)).probe("leaky", argv, cwd: sub)
    raw = File.read(@store.path)
    [ @root, @home, "/etc/passwd", "private/file", "hunter2", "tok-value-plain", "abc\"", secret, Dir.home ].each do |bad|
      refute_includes raw, bad, "stored profile leaked #{bad}"
    end
    entry = JSON.parse(raw)["ops"]["leaky"]
    assert_equal "../bin/run", entry["command"][0], "relative to the recorded cwd, so replay resolves it"
    assert_equal "--config=../conf/a.yml", entry["command"][1]
    assert_equal "sub", entry["cwd"]
    assert entry["command_redacted"]
    assert_equal "plain", entry["command"].last
    assert_equal "--ok=1", entry["command"][-2]
  end

  def test_env_values_of_the_probe_itself_are_never_stored
    probe_with(FakeRunner.new(ok)).probe("t", %w[true], cwd: @root)
    assert_equal %w[version ops], JSON.parse(File.read(@store.path)).keys
    refute_includes File.read(@store.path), "CF_PROBE_ACTIVE"
  end

  def test_inline_scripts_are_never_stored_verbatim
    probe_with(FakeRunner.new(ok)).probe("shell", [ "sh", "-c", "curl --token secret-example-value https://example.invalid" ], cwd: @root)
    probe_with(FakeRunner.new(ok)).probe("rb", [ "ruby", "-e", "puts ENV['X']" ], cwd: @root)
    raw = File.read(@store.path)
    refute_includes raw, "secret-example-value"
    refute_includes raw, "puts ENV"
    assert_equal [ "sh", "-c", "<script>" ], @store.ops["shell"]["command"]
    assert @store.ops["shell"]["command_redacted"]
    assert @store.ops["rb"]["command_redacted"]
  end

  def test_repo_executable_is_recorded_so_replay_resolves_it
    tool = File.join(@root, "my-probe-tool")
    File.write(tool, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, tool)
    sub = File.join(@root, "pkg")
    FileUtils.mkdir_p(sub)
    File.write(File.join(sub, "data.txt"), "x")
    probe_with(FakeRunner.new(ok)).probe("tool", [ tool, File.join(sub, "data.txt") ], cwd: sub)
    entry = @store.ops["tool"]
    assert_equal [ "../my-probe-tool", "./data.txt" ], entry["command"]
    refute entry["command_redacted"]
    res = RP::Runner.new(tree: Struct.new(:x) { def rss_mb(_) = 1.0 }.new, disk: Struct.new(:x) { def read(_) = { free_gb: 1.0, used_gb: 1.0 } }.new,
                         interval: 0.05).run(entry["command"], root: @root, cwd: File.join(@root, entry["cwd"]))
    assert_equal 0, res[:exit], "replayed from the recorded cwd the executable resolves"
    top = probe_with(FakeRunner.new(ok))
    top.probe("top", [ tool ], cwd: @root)
    assert_equal [ "./my-probe-tool" ], @store.ops["top"]["command"]
  end

  def test_worktree_probe_uses_the_checkout_root_not_the_main_checkout
    main = File.realpath(Dir.mktmpdir("probe-main"))
    wt = File.join(File.realpath(Dir.mktmpdir("probe-wt-parent")), "wt")
    git = ->(*a) { system("git", "-C", main, *a, out: File::NULL, err: File::NULL) || flunk("git #{a.join(' ')} failed") }
    git.call("init", "-q")
    git.call("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "x")
    git.call("worktree", "add", "-q", wt)
    File.write(File.join(wt, "Gemfile.lock"), "worktree only")
    ident = RP.identity(wt)
    assert_equal File.realpath(wt), ident.root
    assert_equal CfProjectIdentity.for(main).slug, ident.slug, "the store key stays shared"
    refute_equal ResourceFingerprint.compute(main), ResourceFingerprint.compute(ident.root)
    sub = File.join(wt, "app")
    FileUtils.mkdir_p(sub)
    RP::Probe.new(root: ident.root, store: RP::Store.new(slug: ident.slug, home: @home), runner: FakeRunner.new(ok)).probe("w", %w[true], cwd: sub)
    assert_equal "app", RP::Store.new(slug: ident.slug, home: @home).ops["w"]["cwd"]
  ensure
    FileUtils.rm_rf([ main, File.dirname(wt.to_s) ])
  end

  def test_gate_staleness_follows_the_worktree_checkout
    main = File.realpath(Dir.mktmpdir("probe-main"))
    wt = File.join(File.realpath(Dir.mktmpdir("probe-wt-parent")), "wt")
    git = ->(*a) { system("git", "-C", main, *a, out: File::NULL, err: File::NULL) || flunk("git failed") }
    git.call("init", "-q")
    git.call("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "x")
    git.call("worktree", "add", "-q", wt)
    ident = RP.identity(wt)
    RP::Probe.new(root: ident.root, store: RP::Store.new(slug: ident.slug, home: @home), runner: FakeRunner.new(ok)).probe("w", %w[true], cwd: wt)
    assert_nil ResourceGate.load_profile(wt, home: @home)["w"]["stale"]
    File.write(File.join(wt, "Gemfile.lock"), "changed in the worktree")
    assert_equal true, ResourceGate.load_profile(wt, home: @home)["w"]["stale"]
  ensure
    FileUtils.rm_rf([ main, File.dirname(wt.to_s) ])
  end

  def test_benchmark_keeps_sampling_docker_for_ops_that_measured_it
    probe_with(FakeRunner.new(ok(dmem: 500))).probe("compose_up", %w[sh run.sh], cwd: @root)
    probe_with(FakeRunner.new(ok)).probe("plain", %w[true], cwd: @root)
    runner = FakeRunner.new(ok(dmem: 500))
    cli(%w[benchmark compose_up plain], runner: runner)
    assert_kind_of RP::DockerSampler, runner.calls[0][:docker]
    assert_nil runner.calls[1][:docker]
  end

  def test_probe_chooses_docker_sampler_from_the_command
    runner = FakeRunner.new(ok)
    probe_with(runner).probe("build", %w[docker build .], cwd: @root)
    probe_with(runner).probe("rake_test", %w[rake test], cwd: @root)
    assert_kind_of RP::DockerSampler, runner.calls[0][:docker]
    assert_nil runner.calls[1][:docker]
  end

  def test_fingerprint_covers_nested_dependency_files_but_not_vendored_trees
    base = ResourceFingerprint.compute(@root)
    FileUtils.mkdir_p(File.join(@root, "site"))
    File.write(File.join(@root, "site", "package-lock.json"), "{}")
    nested = ResourceFingerprint.compute(@root)
    refute_equal base, nested
    File.write(File.join(@root, "site", "package-lock.json"), "{\"v\":2}")
    refute_equal nested, ResourceFingerprint.compute(@root)
    FileUtils.mkdir_p(File.join(@root, "site", "node_modules", "dep"))
    File.write(File.join(@root, "site", "node_modules", "dep", "package-lock.json"), "x")
    FileUtils.mkdir_p(File.join(@root, "other", ".git"))
    File.write(File.join(@root, "other", "Gemfile.lock"), "another checkout")
    assert_equal ResourceFingerprint.compute(@root), ResourceFingerprint.compute(@root)
    File.write(File.join(@root, "site", "node_modules", "dep", "package-lock.json"), "y")
    File.write(File.join(@root, "other", "Gemfile.lock"), "changed")
    File.write(File.join(@root, "site", "Dockerfile.dev"), "FROM x")
    with_docker = ResourceFingerprint.compute(@root)
    refute_equal nested, with_docker
    File.write(File.join(@root, "site", "node_modules", "dep", "package-lock.json"), "z")
    assert_equal with_docker, ResourceFingerprint.compute(@root)
  end

  def test_cwd_outside_the_repo_is_stored_as_dot
    outside = File.realpath(Dir.mktmpdir("probe-out"))
    probe_with(FakeRunner.new(ok)).probe("t", %w[true], cwd: outside)
    assert_equal ".", @store.ops["t"]["cwd"]
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_concurrent_writers_never_lose_an_op
    threads = 8.times.map do |i|
      Thread.new { probe_with(FakeRunner.new(ok(rss: 100 + i))).probe("op#{i}", %w[true], cwd: @root) }
    end
    threads.each(&:join)
    assert_equal 8, @store.ops.length
    assert_equal [], Dir.glob("#{@store.path}.*.tmp")
  end

  def test_corrupt_profile_reads_as_empty_and_is_replaced
    FileUtils.mkdir_p(File.dirname(@store.path))
    File.write(@store.path, "{not json")
    probe_with(FakeRunner.new(ok)).probe("t", %w[true], cwd: @root)
    assert_equal [ "t" ], @store.ops.keys
  end

  def test_tree_sampler_sums_descendants_only
    ps = "  10 1 1024\n  11 10 2048\n  12 11 1024\n  20 1 99999\n"
    sampler = RP::TreeSampler.new(runner: ->(*) { ps })
    assert_in_delta 4.0, sampler.rss_mb(10), 0.001
    assert_in_delta 1.0, sampler.rss_mb(12), 0.001
  end

  def test_disk_sampler_reads_df_and_du
    out = { "df" => "Filesystem 1024-blocks Used Available Capacity\n/dev/x 100 1 1048576 1%\n", "du" => "2097152\t/repo\n" }
    r = RP::DiskSampler.new(runner: ->(cmd, *) { out.fetch(cmd) }).read("/repo")
    assert_in_delta 1.0, r[:free_gb], 0.001
    assert_in_delta 2.0, r[:used_gb], 0.001
  end

  def test_docker_sampler_sums_stats_and_system_df
    rows = {
      "stats" => %({"MemUsage":"512MiB / 8GiB"}\n{"MemUsage":"1GiB / 8GiB"}\n),
      "system" => %({"Type":"Images","Size":"2GB"}\n{"Type":"Containers","Size":"9GB"}\n{"Type":"Build Cache","Size":"1GB"}\n)
    }
    d = RP::DockerSampler.new(runner: ->(_docker, sub, *) { rows.fetch(sub) })
    assert_in_delta 1536.0, d.mem_mb, 0.01
    assert_in_delta 3.0, d.disk_gb, 0.01
    broken = RP::DockerSampler.new(runner: ->(*) { raise Errno::ENOENT })
    assert_equal 0.0, broken.mem_mb
    assert_equal 0.0, broken.disk_gb
  end

  def test_docker_sampler_used_only_for_docker_ops
    assert_nil RP.docker_sampler("rake_test", %w[bundle exec rake test])
    assert_kind_of RP::DockerSampler, RP.docker_sampler("compose_up", %w[sh -c x])
    assert_kind_of RP::DockerSampler, RP.docker_sampler("build", %w[docker build .])
  end

  def test_runner_measures_with_injected_samplers_and_passes_exit_status
    tree = Struct.new(:peak) { def rss_mb(_) = peak }.new(321.4)
    disk = Class.new do
      def initialize = @n = 0

      def read(_)
        @n += 1
        @n == 1 ? { free_gb: 50.0, used_gb: 1.0 } : { free_gb: 48.5, used_gb: 1.2 }
      end
    end.new
    docker = Class.new do
      def initialize = @m = [ 100.0, 100.0, 700.0 ]
      def mem_mb = @m.length > 1 ? @m.shift : @m.first
      def disk_gb = 2.0
    end.new
    runner = RP::Runner.new(tree: tree, disk: disk, interval: 0.05)
    res = runner.run([ RbConfig.ruby, "-e", "sleep 0.2; exit 3" ], root: @root, cwd: @root, docker: docker)
    assert_equal 3, res[:exit]
    assert_nil res[:signal]
    assert_equal 321, res[:peak_rss_mb]
    assert_equal 1.5, res[:disk_delta_gb]
    assert_operator res[:samples], :>=, 2
    assert_equal 600, res[:docker_mem_peak_mb]
  end

  def test_runner_sets_probe_active_in_the_child
    out = File.join(@root, "env.txt")
    tree = Struct.new(:x) { def rss_mb(_) = 1.0 }.new
    disk = Struct.new(:x) { def read(_) = { free_gb: 1.0, used_gb: 1.0 } }.new
    RP::Runner.new(tree: tree, disk: disk, interval: 0.05)
              .run([ RbConfig.ruby, "-e", "File.write(ARGV[0], ENV['CF_PROBE_ACTIVE'])", out ], root: @root, cwd: @root)
    assert_equal "1", File.read(out)
  end

  def test_runner_reports_a_child_signal_without_signaling_anything_real
    tree = Struct.new(:x) { def rss_mb(_) = 1.0 }.new
    disk = Struct.new(:x) { def read(_) = { free_gb: 1.0, used_gb: 1.0 } }.new
    res = RP::Runner.new(tree: tree, disk: disk, interval: 0.05)
                    .run([ RbConfig.ruby, "-e", "Process.kill('TERM', Process.pid); sleep 5" ], root: @root, cwd: @root)
    assert_equal "TERM", res[:signal]
    assert_nil res[:exit]
  end

  def test_runner_missing_command_is_127
    res = RP::Runner.new.run([ "/nonexistent/cf-probe-cmd" ], root: @root, cwd: @root)
    assert_equal 127, res[:exit]
  end

  def cli(argv, env: {}, runner: nil, killer: ->(sig) { "killed:#{sig}" })
    out = StringIO.new
    err = StringIO.new
    code = RP.run([ "--project", @root ] + argv, env: env, out: out, err: err, home: @home, runner: runner, killer: killer)
    [ code, out.string, err.string ]
  end

  def test_cli_probe_passes_child_exit_code_through
    code, = cli([ "probe", "t" ] + [ "--", RbConfig.ruby, "-e", "exit 7" ], runner: FakeRunner.new(ok.merge(exit: 7)))
    assert_equal 7, code
  end

  def test_cli_probe_relays_the_signal_through_the_killer
    code, = cli([ "probe", "t", "--", "x" ], runner: FakeRunner.new(ok.merge(exit: nil, signal: "INT")))
    assert_equal "killed:INT", code
  end

  def test_cli_nested_probe_never_wraps_or_records_again
    runner = FakeRunner.new(ok)
    code, = cli([ "probe", "t", "--", RbConfig.ruby, "-e", "exit 4" ], env: { "CF_PROBE_ACTIVE" => "1" }, runner: runner)
    assert_equal 4, code
    assert_empty runner.calls
    assert_empty @store.ops
  end

  def test_cli_nested_probe_relays_child_signal
    code, = cli([ "probe", "t", "--", RbConfig.ruby, "-e", "Process.kill('HUP', Process.pid); sleep 5" ],
                env: { "CF_PROBE_ACTIVE" => "1" })
    assert_equal "killed:HUP", code
  end

  def test_cli_probe_requires_op_and_command
    code, _, err = cli([ "probe", "t" ])
    assert_equal 2, code
    assert_match(/usage/, err)
    code, = cli([ "bogus" ])
    assert_equal 2, code
  end

  def test_cli_probe_passes_prereqs_into_the_profile
    cli([ "probe", "change_lanes", "--prereq", "change_boot", "--", "x" ], runner: FakeRunner.new(ok))
    assert_equal [ "change_boot" ], @store.ops["change_lanes"]["prereqs"]
  end

  def test_benchmark_unknown_op_exits_2_and_runs_nothing
    runner = FakeRunner.new(ok)
    code, _, err = cli(%w[benchmark nope], runner: runner)
    assert_equal 2, code
    assert_match(/unknown op nope/, err)
    assert_empty runner.calls
  end

  def test_benchmark_runs_registered_op_with_recorded_command_and_cwd
    sub = File.join(@root, "web")
    FileUtils.mkdir_p(sub)
    probe_with(FakeRunner.new(ok)).probe("web_build", %w[npm run build], cwd: sub)
    runner = FakeRunner.new(ok(rss: 800))
    code, out, = cli(%w[benchmark web_build], runner: runner)
    assert_equal 0, code
    assert_match(/ran: web_build/, out)
    assert_equal %w[npm run build], runner.calls.first[:argv]
    assert_equal sub, runner.calls.first[:cwd]
  end

  def test_benchmark_skips_op_with_missing_prereq_and_reports_it
    probe_with(FakeRunner.new(ok)).probe("change_lanes", %w[lanes], cwd: @root, prereqs: [ "change_boot" ])
    runner = FakeRunner.new(ok)
    code, out, = cli(%w[benchmark change_lanes], runner: runner)
    assert_equal 1, code
    assert_match(/skipped change_lanes: prereq change_boot is not registered/, out)
    assert_empty runner.calls
  end

  def test_benchmark_runs_prereqs_first_and_skips_redacted_commands
    probe_with(FakeRunner.new(ok)).probe("change_boot", %w[boot], cwd: @root)
    probe_with(FakeRunner.new(ok)).probe("change_lanes", %w[lanes], cwd: @root, prereqs: [ "change_boot" ])
    probe_with(FakeRunner.new(ok)).probe("secret_op", %w[run --token abc], cwd: @root)
    runner = FakeRunner.new(ok)
    code, out, = cli(%w[benchmark change_lanes secret_op], runner: runner)
    assert_equal 1, code
    assert_equal [ %w[boot], %w[lanes] ], runner.calls.map { |c| c[:argv] }
    assert_match(/skipped secret_op: command had redacted values/, out)
  end

  def test_benchmark_reports_a_failing_run_as_skipped
    probe_with(FakeRunner.new(ok)).probe("t", %w[true], cwd: @root)
    code, out, = cli(%w[benchmark t], runner: FakeRunner.new(ok.merge(exit: 9)))
    assert_equal 1, code
    assert_match(/skipped t: exited 9/, out)
  end

  def test_benchmark_without_ops_is_usage_error
    code, = cli(%w[benchmark])
    assert_equal 2, code
  end

  def test_show_lists_ops_with_staleness_and_lower_bound_note
    probe_with(FakeRunner.new(ok(rss: 700))).probe("rake_test", %w[rake], cwd: @root)
    code, out, = cli(%w[show])
    assert_equal 0, code
    assert_match(/rake_test: peak_rss_mb=700/, out)
    assert_match(/STALE \(older than TTL\)/, out, "a 1970 timestamp is far past the TTL")
    assert_match(/lower bounds/, out)
  end

  def test_show_reports_fresh_and_empty
    code, out, = cli(%w[show])
    assert_equal 0, code
    assert_match(/no profile recorded yet/, out)
    RP::Probe.new(root: @root, store: @store, runner: FakeRunner.new(ok)).probe("t", %w[true], cwd: @root)
    _, out, = cli(%w[show])
    assert_match(/ fresh$/, out)
    _, json, = cli(%w[show --json])
    assert_equal 500, JSON.parse(json)["t"]["peak_rss_mb"]
  end
end
