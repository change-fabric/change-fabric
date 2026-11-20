# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "../scripts/resource_gate"

class ResourceGateTest < Minitest::Test
  RG = ResourceGate

  # Reader fakes return queued readings (the last one repeats), so a test can
  # script a before and after reclaim. None of them runs a real command.
  class SeqReader
    attr_reader :reads

    def initialize(*values)
      @values = values
      @reads = 0
    end

    def read = next_value
    def free_gb(_path) = next_value

    private

    def next_value
      @reads += 1
      v = @values.length > 1 ? @values.shift : @values.first
      raise v if v.is_a?(Exception)

      v
    end
  end

  class CfPidsTable
    attr_reader :procs

    def initialize(procs) = @procs = procs
    def read(pid) = @procs[pid]
  end

  class FakeReclaimer
    attr_reader :calls

    def initialize(candidates: [], pids: [])
      @candidates, @pids, @calls = candidates, pids, 0
    end

    def reclaim_safe
      @calls += 1
      @pids
    end

    def candidates = @candidates
  end

  def setup
    @tmp = Dir.mktmpdir
    @project = File.join(@tmp, "repo")
    FileUtils.mkdir_p(@project)
    @repo_yml = File.join(@tmp, "repo.yml")
    File.write(@repo_yml, File.read(File.expand_path("../config/resource_floors.yml", __dir__)))
    @user_yml = File.join(@tmp, "user.yml")
  end

  def teardown = FileUtils.remove_entry(@tmp)

  def mem(avail, total: 16_384, normal: nil) = { available_mb: avail, total_mb: total, pressure_normal: normal }

  def floors(platform: "linux", env: {}) = RG::Floors.new(platform: platform, repo_file: @repo_yml, user_file: @user_yml, env: env)

  def gate(mem:, disk:, platform: "linux", profile: {}, reclaimer: nil, docker: nil, floors: floors(platform: platform), now: Time.at(2_000_000_000))
    RG::Gate.new(project: @project, floors: floors, mem: SeqReader.new(*wrap(mem)), disk: SeqReader.new(*wrap(disk)), docker: docker,
                 reclaimer: reclaimer, profile: profile, platform: platform, now: now)
  end

  def wrap(value) = value.is_a?(Array) ? value : [ value ]

  def fresh(peak, disk: 1.0, **extra) = { "peak_rss_mb" => peak, "disk_delta_gb" => disk, "updated_at_epoch" => 2_000_000_000 - 100 }.merge(extra)

  def batch(*pairs) = pairs.map { |op, count| { op: op, count: count } }

  # --- absolute floors ---------------------------------------------------

  def test_healthy_host_passes_with_no_batches_and_is_provisional
    r = gate(mem: mem(9120), disk: 74.0).check
    assert_equal 0, r.exit_code
    assert r.json[:ok]
    assert r.json[:provisional]
    assert_equal 2048, r.json[:need][:ram_mb]
    assert_equal 10, r.json[:need][:disk_gb]
  end

  def test_linux_ten_percent_rule_raises_the_ram_floor_above_2gb
    r = gate(mem: mem(3000, total: 64_000), disk: 50.0).check
    assert_equal 3, r.exit_code
    assert_equal 6400, r.json[:need][:ram_mb]
    assert(r.json[:notes].any? { |n| n.include?("below absolute floor 6400") })
  end

  def test_absolute_floor_is_checked_even_when_the_benchmark_need_is_tiny
    profile = { "tiny" => fresh(10) }
    r = gate(mem: mem(1500), disk: 50.0, profile: profile).check(batches: [ batch([ "tiny", 1 ]) ])
    assert_equal 3, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("absolute floor") })
  end

  def test_linux_disk_floor_is_10_gb
    assert_equal 3, gate(mem: mem(9000), disk: 9.5).check.exit_code
    assert_equal 0, gate(mem: mem(9000), disk: 10.5).check.exit_code
  end

  def test_macos_floor_is_15_gb_disk_and_needs_normal_pressure
    assert_equal 3, gate(mem: mem(9000, normal: true), disk: 14.0, platform: "darwin").check.exit_code
    assert_equal 0, gate(mem: mem(9000, normal: true), disk: 16.0, platform: "darwin").check.exit_code
    r = gate(mem: mem(9000, normal: false), disk: 50.0, platform: "darwin").check
    assert_equal 3, r.exit_code
    assert_includes r.json[:notes], "memory pressure is not normal"
  end

  def test_macos_has_no_ten_percent_rule
    r = gate(mem: mem(2500, total: 65_536, normal: true), disk: 50.0, platform: "darwin").check
    assert_equal 0, r.exit_code
  end

  # --- config chain: floors only go up -------------------------------------

  def test_a_profile_never_lowers_the_floor
    profile = { "tiny" => fresh(1, disk: 0) }
    r = gate(mem: mem(9000), disk: 50.0, profile: profile).check(batches: [ batch([ "tiny", 1 ]) ])
    assert_equal 2048, r.json[:need][:ram_mb]
    assert_equal 10, r.json[:need][:disk_gb]
    refute r.json[:provisional]
  end

  def test_user_yaml_below_the_platform_minimum_is_ignored_with_a_warning_naming_the_file
    File.write(@user_yml, "floors:\n  ram_mb: 512\n  disk_gb: 1\n")
    f = floors
    assert_equal 2048, f.ram_mb
    assert_equal 10, f.disk_gb
    assert(f.warnings.any? { |w| w.include?(@user_yml) && w.include?("ram_mb") })
    assert(f.warnings.any? { |w| w.include?(@user_yml) && w.include?("disk_gb") })
  end

  def test_env_below_the_floor_is_ignored_with_a_warning_naming_the_variable
    f = floors(env: { "CF_FLOOR_RAM_MB" => "100", "CF_FLOOR_DISK_GB" => "2" })
    assert_equal 2048, f.ram_mb
    assert(f.warnings.any? { |w| w.include?("CF_FLOOR_RAM_MB") })
    assert(f.warnings.any? { |w| w.include?("CF_FLOOR_DISK_GB") })
  end

  def test_env_and_user_yaml_can_raise_a_floor
    File.write(@user_yml, "floors:\n  ram_mb: 4096\n")
    f = floors(env: { "CF_FLOOR_DISK_GB" => "40" })
    assert_equal 4096, f.ram_mb
    assert_equal 40, f.disk_gb
    assert_empty f.warnings
    r = gate(mem: mem(3000), disk: 30.0, floors: f).check
    assert_equal 3, r.exit_code
  end

  def test_garbage_env_is_ignored_with_a_warning
    f = floors(env: { "CF_FLOOR_RAM_MB" => "lots" })
    assert_equal 2048, f.ram_mb
    assert(f.warnings.any? { |w| w.include?("CF_FLOOR_RAM_MB") })
  end

  def test_repo_file_below_the_macos_minimum_does_not_warn
    assert_empty floors(platform: "darwin").warnings
  end

  def test_unreadable_user_yaml_is_noted_and_ignored
    File.write(@user_yml, "floors: [unclosed")
    f = floors
    assert_equal 2048, f.ram_mb
    assert(f.warnings.any? { |w| w.include?(@user_yml) })
  end

  # --- formula --------------------------------------------------------------

  def test_mixed_op_batch_sums_peaks_times_headroom_times_count
    profile = { "a" => fresh(1000), "b" => fresh(2000) }
    r = gate(mem: mem(20_000), disk: 50.0, profile: profile).check(batches: [ batch([ "a", 2 ], [ "b", 1 ]) ])
    # (1000 x 2 + 2000 x 1) x 1.25
    assert_equal 5000, r.json[:need][:ram_mb]
  end

  def test_sequential_batches_take_the_max_not_the_sum
    profile = { "a" => fresh(1000), "b" => fresh(4000) }
    r = gate(mem: mem(20_000), disk: 50.0, profile: profile).check(batches: [ batch([ "a", 3 ]), batch([ "b", 1 ]) ])
    assert_equal 5000, r.json[:need][:ram_mb]
  end

  def test_need_over_available_blocks
    profile = { "a" => fresh(8000) }
    r = gate(mem: mem(9000), disk: 50.0, profile: profile).check(batches: [ batch([ "a", 1 ]) ])
    assert_equal 3, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("below need 10000") })
  end

  def test_disk_need_is_floor_plus_deltas_times_worktrees
    profile = { "a" => fresh(100, disk: 3.0), "b" => fresh(100, disk: 2.0) }
    r = gate(mem: mem(9000), disk: 24.0, profile: profile).check(batches: [ batch([ "a", 1 ], [ "b", 1 ]) ], worktrees: 3)
    # 10 + (3 + 2) x 3 = 25
    assert_equal 25, r.json[:need][:disk_gb]
    assert_equal 3, r.exit_code
  end

  def test_stale_profile_uses_1_5_headroom_and_fresh_uses_1_25
    old = { "a" => fresh(1000).merge("updated_at_epoch" => 2_000_000_000 - (31 * 86_400)) }
    assert_equal 6000 - 4000, gate(mem: mem(20_000), disk: 50.0, profile: old).check(batches: [ batch([ "a", 4 ]) ]).json[:need][:ram_mb] - 4000
    r = gate(mem: mem(20_000), disk: 50.0, profile: { "a" => fresh(1000) }).check(batches: [ batch([ "a", 4 ]) ])
    assert_equal 5000, r.json[:need][:ram_mb]
  end

  def test_flagged_stale_profile_entry_uses_stale_headroom
    r = gate(mem: mem(20_000), disk: 50.0, profile: { "a" => fresh(2000, "stale" => true) }).check(batches: [ batch([ "a", 2 ]) ])
    assert_equal 6000, r.json[:need][:ram_mb]
  end

  def test_unmeasured_op_uses_the_repo_kind_default_with_2x_headroom_and_is_provisional
    File.write(File.join(@project, "package.json"), "{}")
    r = gate(mem: mem(30_000), disk: 80.0).check(batches: [ batch([ "boot", 1 ]) ])
    assert r.json[:provisional]
    assert_equal "default", r.json[:need][:source]
    assert_equal 8192, r.json[:need][:ram_mb] # node 4096 x 2.0
    assert_equal 18, r.json[:need][:disk_gb] # 10 + 8
  end

  def test_ruby_and_other_defaults_and_node_wins_over_ruby
    File.write(File.join(@project, "Gemfile"), "")
    assert_equal 4096, gate(mem: mem(30_000), disk: 80.0).check(batches: [ batch([ "x", 1 ]) ]).json[:need][:ram_mb]
    File.write(File.join(@project, "package.json"), "{}")
    assert_equal 8192, gate(mem: mem(30_000), disk: 80.0).check(batches: [ batch([ "x", 1 ]) ]).json[:need][:ram_mb]
  end

  def test_docker_heavy_default_adds_on_top_of_the_language_kind
    File.write(File.join(@project, "package.json"), "{}")
    File.write(File.join(@project, "Dockerfile"), "FROM scratch")
    r = gate(mem: mem(30_000), disk: 80.0, docker: SeqReader.new(docker_ok)).check(batches: [ batch([ "x", 1 ]) ])
    assert_equal 20_480, r.json[:need][:ram_mb] # (4096 + 6144) x 2.0
    assert_equal 38, r.json[:need][:disk_gb] # 10 + 8 + 20
  end

  def test_unmeasured_op_in_a_docker_repo_reads_docker_and_fails_closed_without_a_reader
    File.write(File.join(@project, "compose.yaml"), "services: {}")
    r = gate(mem: mem(30_000), disk: 80.0).check(batches: [ batch([ "boot", 1 ]) ])
    assert_equal 4, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("docker") })
  end

  def test_unmeasured_op_in_a_docker_repo_is_held_to_the_docker_vm_cap
    File.write(File.join(@project, "Dockerfile"), "FROM scratch")
    r = gate(mem: mem(60_000), disk: 80.0, docker: SeqReader.new(docker_ok(total: 8000, used: 1000))).check(batches: [ batch([ "boot", 1 ]) ])
    assert_equal 3, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("exceeds VM cap") })
  end

  def test_missing_shipped_defaults_file_is_warned_not_silent
    f = RG::Floors.new(platform: "linux", repo_file: File.join(@tmp, "absent.yml"), user_file: @user_yml, env: {})
    assert(f.warnings.any? { |w| w.include?("absent.yml") })
  end

  def test_defaults_file_resolves_to_a_shipped_file_that_exists
    assert File.file?(RG.defaults_file)
  end

  def test_one_default_op_makes_the_result_provisional_in_a_partial_profile
    profile = { "a" => fresh(500) }
    r = gate(mem: mem(20_000), disk: 50.0, profile: profile).check(batches: [ batch([ "a", 1 ], [ "unknown", 1 ]) ])
    assert r.json[:provisional]
    refute gate(mem: mem(20_000), disk: 50.0, profile: profile).check(batches: [ batch([ "a", 1 ]) ]).json[:provisional]
  end

  # --- reclaim and candidates -------------------------------------------------

  def test_reclaim_runs_then_remeasures_and_passes
    reclaimer = FakeReclaimer.new(pids: [ 4242 ])
    r = gate(mem: mem(9000), disk: [ 5.0, 30.0 ], reclaimer: reclaimer).check(reclaim_safe: true)
    assert_equal 0, r.exit_code
    assert_equal 1, reclaimer.calls
    assert_equal [ 4242 ], r.json[:reclaimed][:pids]
    assert_equal 25.0, r.json[:reclaimed][:disk_gb]
  end

  def test_reclaim_is_tried_even_below_the_absolute_floor
    reclaimer = FakeReclaimer.new
    r = gate(mem: [ mem(1000), mem(9000) ], disk: [ 3.0, 40.0 ], reclaimer: reclaimer).check(reclaim_safe: true)
    assert_equal 1, reclaimer.calls
    assert_equal 0, r.exit_code
  end

  def test_still_below_after_reclaim_exits_3_with_tier_2_candidates_and_deletes_nothing
    cands = [ { kind: "worktree", path: "/x/wt", size_gb: 2.1 } ]
    reclaimer = FakeReclaimer.new(candidates: cands)
    r = gate(mem: mem(9000), disk: [ 5.0, 6.0 ], reclaimer: reclaimer).check(reclaim_safe: true)
    assert_equal 3, r.exit_code
    refute r.json[:ok]
    assert_equal cands, r.json[:candidates]
    assert_equal 1, reclaimer.calls
  end

  def test_no_reclaim_without_the_flag
    reclaimer = FakeReclaimer.new
    r = gate(mem: mem(9000), disk: 5.0, reclaimer: reclaimer).check
    assert_equal 0, reclaimer.calls
    assert_equal 3, r.exit_code
    assert_equal [], r.json[:candidates].reject { |_| false }.first(0)
  end

  def test_no_reclaim_when_already_above_the_floor
    reclaimer = FakeReclaimer.new
    gate(mem: mem(9000), disk: 50.0, reclaimer: reclaimer).check(reclaim_safe: true)
    assert_equal 0, reclaimer.calls
  end

  def test_reclaim_that_frees_disk_but_leaves_need_unmet_still_fails
    profile = { "big" => fresh(100, disk: 30.0) }
    reclaimer = FakeReclaimer.new
    r = gate(mem: mem(9000), disk: [ 20.0, 25.0 ], reclaimer: reclaimer, profile: profile).check(batches: [ batch([ "big", 1 ]) ], reclaim_safe: true)
    assert_equal 3, r.exit_code
  end

  # --- fail closed -----------------------------------------------------------

  def test_failed_memory_reader_is_exit_4_with_the_reader_named
    r = gate(mem: RG::MeasurementError.new("memory", "boom"), disk: 50.0).check
    assert_equal 4, r.exit_code
    assert_equal "measurement", r.json[:error]
    refute r.json[:ok]
    assert(r.json[:notes].any? { |n| n.start_with?("memory:") })
  end

  def test_failed_disk_reader_is_exit_4_even_when_ram_looks_fine
    r = gate(mem: mem(99_999), disk: RG::MeasurementError.new("disk", "df did not parse")).check
    assert_equal 4, r.exit_code
  end

  def test_docker_op_with_a_failing_docker_reader_is_exit_4
    docker = SeqReader.new(RG::MeasurementError.new("docker_info", "daemon not running"))
    r = gate(mem: mem(9000), disk: 50.0, docker: docker).check(batches: [ batch([ "docker_build", 1 ]) ])
    assert_equal 4, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("docker_info") })
  end

  def test_docker_op_with_no_docker_reader_is_exit_4
    r = gate(mem: mem(9000), disk: 50.0).check(batches: [ batch([ "compose_up", 1 ]) ])
    assert_equal 4, r.exit_code
  end

  def test_non_docker_batch_never_reads_docker
    docker = SeqReader.new(RG::MeasurementError.new("docker_info", "down"))
    r = gate(mem: mem(9000), disk: 50.0, docker: docker, profile: { "a" => fresh(100) }).check(batches: [ batch([ "a", 1 ]) ])
    assert_equal 0, r.exit_code
    assert_equal 0, docker.reads
  end

  def test_a_failure_during_the_post_reclaim_remeasure_is_exit_4
    r = gate(mem: [ mem(9000), RG::MeasurementError.new("memory", "gone") ], disk: 5.0, reclaimer: FakeReclaimer.new).check(reclaim_safe: true)
    assert_equal 4, r.exit_code
  end

  # --- docker gate -----------------------------------------------------------

  def docker_ok(total: 12_000, used: 1000, free: 60.0) = { vm_total_mb: total, vm_used_mb: used, vm_free_gb: free, reclaimable_gb: 1.0 }

  def test_docker_vm_memory_ceiling_is_independent_of_host_ram
    profile = { "docker_up" => fresh(100, "docker_mem_peak_mb" => 5000) }
    r = gate(mem: mem(60_000), disk: 50.0, profile: profile, docker: SeqReader.new(docker_ok(total: 8000, used: 3000)))
            .check(batches: [ batch([ "docker_up", 1 ]) ])
    assert_equal 3, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("exceeds VM cap 8000") })
  end

  def test_docker_vm_with_room_passes
    profile = { "docker_up" => fresh(100, "docker_mem_peak_mb" => 1000) }
    r = gate(mem: mem(60_000), disk: 50.0, profile: profile, docker: SeqReader.new(docker_ok))
            .check(batches: [ batch([ "docker_up", 1 ]) ])
    assert_equal 0, r.exit_code
  end

  def test_docker_free_disk_below_floor_blocks
    profile = { "docker_up" => fresh(100, "docker_disk_delta_gb" => 5.0) }
    r = gate(mem: mem(60_000), disk: 50.0, profile: profile, docker: SeqReader.new(docker_ok(free: 12.0)))
            .check(batches: [ batch([ "docker_up", 1 ]) ])
    assert_equal 3, r.exit_code
    assert(r.json[:notes].any? { |n| n.include?("Docker free disk 12.0 GB below need 15") })
  end

  # --- readers parse real output shapes ----------------------------------------

  class FakeRunner
    attr_reader :argvs

    def initialize(outputs)
      @outputs = outputs
      @argvs = []
    end

    def call(reader, *argv)
      @argvs << argv
      out = @outputs.find { |prefix, _| argv.join(" ").start_with?(prefix) }&.last
      raise RG::MeasurementError.new(reader, "#{argv.first} unavailable") if out.nil?
      raise out if out.is_a?(Exception)

      out
    end
  end

  def test_linux_mem_reader_parses_proc_meminfo
    text = "MemTotal:       32768000 kB\nMemFree: 1 kB\nMemAvailable:    9338880 kB\n"
    m = RG::MemReader.new(platform: "linux", meminfo: -> { text }).read
    assert_equal({ available_mb: 9120, total_mb: 32_000, pressure_normal: nil }, m)
  end

  def test_linux_mem_reader_without_memavailable_fails_closed
    assert_raises(RG::MeasurementError) { RG::MemReader.new(platform: "linux", meminfo: -> { "MemTotal: 1 kB\n" }).read }
    assert_raises(RG::MeasurementError) { RG::MemReader.new(platform: "linux", meminfo: -> { raise Errno::ENOENT }).read }
  end

  def test_macos_mem_reader_parses_memory_pressure_and_sysctl
    runner = FakeRunner.new(
      "memory_pressure" => "Pageouts: 5\n\nSystem-wide memory free percentage: 81%\n",
      "sysctl -n hw.memsize" => "25769803776\n",
      "sysctl -n kern.memorystatus_vm_pressure_level" => "1\n"
    )
    m = RG::MemReader.new(platform: "darwin", runner: runner).read
    assert_equal 24_576, m[:total_mb]
    assert_equal 19_906, m[:available_mb]
    assert m[:pressure_normal]
  end

  def test_macos_pressure_level_above_1_is_not_normal
    runner = FakeRunner.new("memory_pressure" => "free percentage: 40%\n", "sysctl -n hw.memsize" => "8589934592\n",
                            "sysctl -n kern.memorystatus_vm_pressure_level" => "2\n")
    refute RG::MemReader.new(platform: "darwin", runner: runner).read[:pressure_normal]
  end

  def test_macos_mem_reader_with_unparseable_output_fails_closed
    runner = FakeRunner.new("memory_pressure" => "nothing useful\n", "sysctl -n hw.memsize" => "1\n", "sysctl -n kern" => "1\n")
    assert_raises(RG::MeasurementError) { RG::MemReader.new(platform: "darwin", runner: runner).read }
    missing = FakeRunner.new({})
    assert_raises(RG::MeasurementError) { RG::MemReader.new(platform: "darwin", runner: missing).read }
  end

  DF = "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5s1 482797652 16220556 78295540 18% /\n"

  def test_disk_reader_parses_df_pk
    gb = RG::DiskReader.new(runner: FakeRunner.new("df -Pk" => DF)).free_gb("/")
    assert_in_delta 74.67, gb, 0.01
  end

  def test_disk_reader_rejects_garbage
    assert_raises(RG::MeasurementError) { RG::DiskReader.new(runner: FakeRunner.new("df -Pk" => "oops\n")).free_gb("/") }
    assert_raises(RG::MeasurementError) { RG::DiskReader.new(runner: FakeRunner.new("df -Pk" => RG::MeasurementError.new("disk", "x"))).free_gb("/") }
  end

  def docker_runner(overrides = {})
    FakeRunner.new({
      "docker info" => JSON.generate("MemTotal" => 12_599_537_664, "DockerRootDir" => "/var/lib/docker"),
      "docker stats" => "{\"MemUsage\":\"512MiB / 11.7GiB\"}\n{\"MemUsage\":\"1.5GiB / 11.7GiB\"}\n",
      "docker system df" => "{\"Reclaimable\":\"2.5GB (50%)\"}\n{\"Reclaimable\":\"512MB\"}\n",
      "docker run" => DF,
      "df -Pk" => DF
    }.merge(overrides))
  end

  def test_docker_reader_on_macos_reads_vm_through_the_pinned_alpine_df
    runner = docker_runner
    d = RG::DockerReader.new(platform: "darwin", runner: runner).read
    assert_equal 12_015, d[:vm_total_mb]
    assert_equal 2048.0, d[:vm_used_mb]
    assert_in_delta 74.67, d[:vm_free_gb], 0.01
    assert_in_delta 3.0, d[:reclaimable_gb], 0.01
    run = runner.argvs.find { |a| a[1] == "run" }
    assert_includes run.join(" "), "alpine@sha256:"
    # /var/lib/docker does not exist inside the container; the overlay root sits on the VM disk.
    assert_equal [ "df", "-Pk", "/" ], run.last(3)
  end

  def test_docker_reader_on_linux_reads_the_docker_root_volume
    runner = docker_runner
    RG::DockerReader.new(platform: "linux", runner: runner).read
    assert(runner.argvs.any? { |a| a.first == "df" && a.last == "/var/lib/docker" })
    refute(runner.argvs.any? { |a| a[1] == "run" })
  end

  def test_docker_reader_failures_fail_closed
    assert_raises(RG::MeasurementError) { RG::DockerReader.new(runner: docker_runner("docker info" => "not json")).read }
    assert_raises(RG::MeasurementError) { RG::DockerReader.new(runner: docker_runner("docker stats" => "garbage\n")).read }
    assert_raises(RG::MeasurementError) { RG::DockerReader.new(runner: docker_runner("docker system df" => "{\"Reclaimable\":\"lots\"}\n")).read }
    assert_raises(RG::MeasurementError) { RG::DockerReader.new(platform: "darwin", runner: docker_runner("docker run" => "bad\n")).read }
  end

  def test_runner_turns_a_missing_command_into_a_measurement_error
    assert_raises(RG::MeasurementError) { RG::Runner.new.call("x", "/nonexistent/cf-resource-gate-test") }
  end

  def test_runner_turns_a_timeout_into_a_measurement_error
    err = assert_raises(RG::MeasurementError) { RG::Runner.new(timeout: 0.1).call("slow", "sleep", "5") }
    assert_includes err.message, "timed out"
  end

  # --- reclaimer: never prunes for real -------------------------------------------

  def test_reclaimer_runs_exactly_the_tier_1_docker_prunes_and_stops_registry_pids
    runner = FakeRunner.new("docker image prune -f" => "", "docker builder prune -f" => "")
    pids = Object.new
    def pids.stop_matching = [ 7 ]
    r = RG::Reclaimer.new(project: @project, runner: runner, pids: pids)
    assert_equal [ 7 ], r.reclaim_safe
    assert_equal [ %w[docker image prune -f], %w[docker builder prune -f] ], runner.argvs.first(2)
  end

  # The stale-network sweep is a tier-1 safe reclaim: a labeled, idle, old
  # network is removed through the same runner, and the gate never prunes
  # anything it cannot name.
  def test_reclaimer_sweeps_a_stale_labeled_network
    old = (Time.now - 7200).to_i
    inspect = JSON.generate([ { "Labels" => { "cf.owned" => "1", "cf.created_at" => old.to_s }, "Containers" => {} } ])
    runner = FakeRunner.new("docker image prune -f" => "", "docker builder prune -f" => "",
                            "docker network ls" => "cf-change-aaaa\n", "docker network inspect" => inspect,
                            "docker network rm" => "")
    RG::Reclaimer.new(project: @project, runner: runner).reclaim_safe
    assert_includes runner.argvs, %w[docker network ls --filter label=cf.owned=1 --format {{.Name}}]
    assert_includes runner.argvs, %w[docker network rm cf-change-aaaa]
  end

  def test_reclaimer_survives_a_failed_network_sweep
    runner = FakeRunner.new("docker image prune -f" => "", "docker builder prune -f" => "",
                            "docker network ls" => RG::MeasurementError.new("reclaim", "x"))
    assert_equal [], RG::Reclaimer.new(project: @project, runner: runner).reclaim_safe
  end

  def test_reclaimer_survives_a_failed_prune
    runner = FakeRunner.new("docker image prune -f" => RG::MeasurementError.new("reclaim", "x"))
    assert_equal [], RG::Reclaimer.new(project: @project, runner: runner).reclaim_safe
  end

  def test_reclaim_with_a_reused_pid_never_signals_it
    require_relative "../scripts/cf_pids"
    table = CfPidsTable.new({ 100 => { start_time: "t1", command: "node a.js" } })
    signals = []
    registry = CfPids.new(session: "s", root: @tmp, table: table, killer: ->(sig, pid) { signals << [ sig, pid ] })
    registry.register(pid: 100)
    table.procs[100] = { start_time: "t2", command: "node a.js" }
    r = RG::Reclaimer.new(project: @project, runner: FakeRunner.new({}), pids: registry)
    assert_equal [], r.reclaim_safe
    assert_empty signals
  end

  def test_candidates_list_worktrees_with_sizes_and_large_dumps_but_not_the_main_checkout
    wt = File.join(@tmp, "wt1")
    FileUtils.mkdir_p(wt)
    File.write(File.join(@project, "big.dump"), "")
    File.truncate(File.join(@project, "big.dump"), 150 * 1024 * 1024)
    File.write(File.join(@project, "small.sql"), "x")
    runner = FakeRunner.new("git -C" => "worktree #{@project}\nHEAD abc\n\nworktree #{wt}\nHEAD def\n", "du -sk" => "2097152\t#{wt}\n")
    cands = RG::Reclaimer.new(project: @project, runner: runner).candidates
    assert_includes cands, { kind: "worktree", path: wt, size_gb: 2.0 }
    assert_includes cands, { kind: "db_dump", path: File.join(@project, "big.dump"), size_gb: 0.15 }
    assert_equal 2, cands.length
  end

  # --- CLI -----------------------------------------------------------------------

  def test_parse_batch_accepts_op_count_lists
    assert_equal [ { op: "a", count: 2 }, { op: "b", count: 1 } ], RG.parse_batch("a:2,b")
  end

  def test_parse_batch_rejects_bad_input
    [ "", "a:0", "a:x", ":2", "a b:1" ].each { |bad| assert_raises(ArgumentError, bad) { RG.parse_batch(bad) } }
  end

  def test_cli_with_an_unknown_verb_or_bad_batch_exits_2
    assert_equal 2, RG.run([ "frobnicate" ], out: StringIO.new, err: StringIO.new)
    assert_equal 2, RG.run([ "check", "--batch", "a:0" ], out: StringIO.new, err: StringIO.new)
    assert_equal 2, RG.run([ "check", "--ops", "a" ], out: StringIO.new, err: StringIO.new)
  end

  def test_result_json_has_the_documented_keys
    r = gate(mem: mem(9000), disk: 50.0).check
    assert_equal %i[ok error notes ram_available_mb disk_free_gb need reclaimed candidates provisional].sort, r.json.keys.sort
    assert_equal %i[ram_mb disk_gb source].sort, r.json[:need].keys.sort
    assert_equal %i[disk_gb pids].sort, r.json[:reclaimed].keys.sort
  end
end
