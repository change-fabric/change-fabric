# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_testcases"
require_relative "../scripts/change_testcases_video"

# --export video: the disk budget, the frame spool, the encoder pool, and that
# an export failure never touches a case's verdict.
class ChangeTestcasesVideoTest < Minitest::Test
  MB = ChangeTestcasesVideo::MB

  Ctx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff, :evidence_dir, :run_id, :exports,
                   :video_budget_mb) do
    def log(_message) = nil
    def signoff? = false
  end

  # Grades every case pass: a case passes only on a pass verdict, and these
  # tests assert an export failure leaves a passing case passing.
  class Grader
    def initialize(_reason = nil); end

    def unavailable_reason = nil

    def grade(observations)
      observations.map { |o| ChangeAcceptanceGrader::Verdict.new(id: o[:id], verdict: "pass", rationale: "ok") }
    end
  end
  Status = Struct.new(:ok) { def success? = ok }

  # Writes what a recording module would: step traces, then JPEG frames until
  # its maxBytes share runs out, all into the mounted attempt dir.
  class RecordingSession
    attr_reader :max_bytes

    FRAME = "\xFF\xD8".b + ("x" * (200 * 1024)) + "\xFF\xD9".b

    def initialize(root, fail_ids: [])
      @root = root
      @fail_ids = fail_ids
      @lock = Mutex.new
      @max_bytes = []
    end

    def run_function(code, launch_args: [], timeout_ms: nil)
      dir = File.join(@root, code[%r{const evidence = \{"dir":"/cf-run/([^"]+)"\}}, 1])
      id = code[/"id":"([^"]+)"/, 1]
      File.write(File.join(dir, "step-0001-a.json"), JSON.generate("record" => { "index" => 0, "ok" => true }))
      video = JSON.parse(code[/const video = (.*);$/, 1])
      frames = 0
      if video
        @lock.synchronize { @max_bytes << video["maxBytes"] }
        written = 0
        while written + FRAME.bytesize <= video["maxBytes"] && frames < 40
          frames += 1
          written += FRAME.bytesize
          File.binwrite(File.join(dir, format("frame-a%06d.jpg", frames)), FRAME)
        end
      end
      ok = !@fail_ids.include?(id)
      { "ok" => ok, "steps" => [ { "index" => 0, "label" => "goto /", "ok" => ok, "error" => ok ? nil : "boom" } ],
        "video" => video && { "frames" => frames, "marks" => [ { "ms" => 0, "label" => "goto /" } ], "stopped" => nil },
        "observation" => { "url" => "/", "title" => "t", "text" => "t" } }
    end
  end

  def suite(count)
    cases = (1..count).map do |n|
      "  - id: case-#{n}\n    acceptance: Case #{n} loads.\n    steps:\n      - goto: /\n"
    end
    "suite: long\ncases:\n#{cases.join}"
  end

  def run_lane(count:, free:, runner: nil, parallel: 1, budget_mb: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "long.cf-testcases.yml"), suite(count))
      root = ChangeTestcasesEvidence.prepare(dir, "run-1")
      session = RecordingSession.new(root)
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ], "parallel" => parallel }, dir)
      lane = ChangeLaneTestcases.new(config, Ctx.new(nil, "https://app.example.org", session, [], false, root, "run-1", [ "video" ], budget_mb),
                                     grader: Grader.new("no grader"), video_runner: runner || fake_ffmpeg,
                                     free_space: ->(_dir) { free })
      findings = lane.run
      yield lane, findings, root, session
    end
  end

  def fake_ffmpeg(in_flight: nil)
    lambda do |argv|
      work = argv[argv.index("--mount") + 1][/source=([^"]+)"/, 1]
      in_flight&.call(+1)
      sleep 0.05
      File.write(File.join(work, ChangeTestcasesVideo::OUT_NAME), "mp4")
      in_flight&.call(-1)
      [ "", Status.new(true) ]
    end
  end

  def exports(root) = JSON.parse(File.read(File.join(root, "exports.json")))

  def test_encode_runs_ffmpeg_as_the_host_user_with_no_network
    argv = ChangeTestcasesVideo.encode_argv("/tmp/work")
    assert_equal ChangeDocker.host_user, argv[argv.index("--user") + 1]
    assert_equal "none", argv[argv.index("--network") + 1]
  end

  def test_share_is_free_space_above_the_reserve_capped_and_split
    reserve = ChangeTestcasesVideo.reserve_bytes(4)
    assert_equal 64 * MB + 32 * MB, reserve
    assert_equal 10 * MB, ChangeTestcasesVideo.per_case_bytes(free_bytes: reserve + 40 * MB, case_count: 4)
    assert_equal 1 * MB, ChangeTestcasesVideo.per_case_bytes(free_bytes: 100_000 * MB, case_count: 4, budget_mb: 4)
    assert_equal 0, ChangeTestcasesVideo.per_case_bytes(free_bytes: reserve - 1, case_count: 4)
  end

  def test_captions_follow_the_steps_after_the_title_card
    srt = ChangeTestcasesVideo.srt([ { "ms" => 0, "label" => "goto /" }, { "ms" => 1500, "label" => "click #go" } ], 3000)
    assert_includes srt, "1\n00:00:02,000 --> 00:00:03,500\ngoto /"
    assert_includes srt, "2\n00:00:03,500 --> 00:00:05,000\nclick #go"
  end

  def test_ten_parallel_recorded_cases_stay_within_the_cap_and_memory
    rss = -> { Integer(`ps -o rss= -p #{Process.pid}`.strip) * 1024 }
    before = rss.call
    run_lane(count: 10, free: 10_000 * MB, parallel: 10, budget_mb: 40) do |_lane, findings, root, session|
      grown = rss.call - before
      frame_bytes = Dir.glob(File.join(root, "cases", "**", "frame-*.jpg")).sum { |path| File.size(path) }
      assert_operator frame_bytes, :<=, 40 * MB
      assert(session.max_bytes.all? { |share| share == 4 * MB })
      assert_operator grown, :<, 64 * MB, "Ruby never holds frames"
      assert_equal 10, exports(root)["video"].count { |_key, entry| entry["status"] == "ok" }
      assert_equal 10, Dir.glob(File.join(root, "cases", "long", "*.mp4")).size
      assert(findings.reject { |finding| finding.check.end_with?("acceptance", "grading") }.all? { |finding| finding.status == "pass" })
    end
  end

  def test_no_more_than_two_encodes_run_at_once
    peak = 0
    current = 0
    lock = Mutex.new
    counter = ->(delta) { lock.synchronize { current += delta; peak = [ peak, current ].max } }
    run_lane(count: 6, free: 10_000 * MB, parallel: 6, runner: fake_ffmpeg(in_flight: counter)) do
      assert_operator peak, :<=, ChangeTestcasesVideo::ENCODERS
    end
  end

  # A full disk fails the export, by name, and nothing else.
  def test_a_full_disk_fails_only_the_export
    run_lane(count: 3, free: ChangeTestcasesVideo.reserve_bytes(3) + 1024) do |lane, _findings, root|
      entries = exports(root)["video"]
      assert_equal 3, entries.size
      assert(entries.values.all? { |entry| entry["status"] == "failed" && entry["reason"].include?("not enough free disk") })
      assert_equal %w[pass pass pass], lane.case_records.map(&:status)
    end
  end

  # Just above the reserve: nothing is recorded, and every case still gets its
  # start.json, its step traces and its result.json.
  def test_a_near_full_volume_stops_recording_but_keeps_every_cases_evidence
    run_lane(count: 4, free: ChangeTestcasesVideo.reserve_bytes(4) + (512 * 1024)) do |_lane, _findings, root, session|
      assert_empty session.max_bytes
      assert_empty Dir.glob(File.join(root, "cases", "**", "frame-*.jpg"))
      (1..4).each do |n|
        attempt = File.join(root, "cases", "long", "case-#{n}", "attempt-1")
        %w[start.json step-0001-a.json result.json].each { |name| assert File.exist?(File.join(attempt, name)), "#{name} for case-#{n}" }
      end
    end
  end

  def test_a_failing_case_without_retries_keeps_its_frames_for_its_video
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "long.cf-testcases.yml"), suite(1))
      root = ChangeTestcasesEvidence.prepare(dir, "run-1")
      session = RecordingSession.new(root, fail_ids: [ "long/case-1" ])
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
      ChangeLaneTestcases.new(config, Ctx.new(nil, "https://a.example.org", session, [], false, root, "run-1", [ "video" ], 40),
                              grader: Grader.new("none"), video_runner: fake_ffmpeg, free_space: ->(_d) { 10_000 * MB }).run
      assert_equal "ok", exports(root)["video"]["long/case-1"]["status"]
    end
  end

  def test_an_encode_failure_fails_only_that_export
    failing = ->(_argv) { [ "boom", Status.new(false) ] }
    run_lane(count: 2, free: 10_000 * MB, runner: failing) do |lane, _findings, root|
      assert(exports(root)["video"].values.all? { |entry| entry["status"] == "failed" && entry["reason"].include?("ffmpeg failed") })
      assert_equal %w[pass pass], lane.case_records.map(&:status)
    end
  end

  def test_only_the_last_attempts_frames_are_kept
    Dir.mktmpdir do |dir|
      first = File.join(dir, "attempt-1")
      FileUtils.mkdir_p(first)
      File.write(File.join(first, "frame-a000001.jpg"), "x")
      ChangeTestcasesVideo.drop_frames(first)
      assert_empty ChangeTestcasesVideo.frames(first)
    end
  end

  def test_a_resumed_recording_keeps_both_segments_captions
    lane = ChangeLaneTestcases.allocate
    merged = lane.send(:merged_video, { "frames" => 10, "marks" => [ { "ms" => 0, "label" => "goto /" } ] },
                       { "frames" => 5, "marks" => [ { "ms" => 0, "label" => "goto / again" } ] })
    assert_equal 15, merged["frames"]
    assert_equal [ 0, 2000 ], merged["marks"].map { |mark| mark["ms"] }
  end

  def test_the_resumed_call_records_and_blob_urls_are_revoked
    source = File.read(File.expand_path("../scripts/change_lane_testcases.rb", __dir__))
    assert_includes source, "video: dir && video_js(item, record.dig('video', 'bytes').to_i)),"
    assert_includes source, "URL.revokeObjectURL(url)"
    assert_includes source, "let last = latest;\n            try {\n              last = await casePage.screenshot("
  end

  # A failed attempt's frames are gone before the rerun records its own.
  def test_a_failed_attempts_frames_are_freed_before_the_retry
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "long.cf-testcases.yml"),
                 "suite: long\nsuite_version: 2\ncases:\n  - id: flaky\n    acceptance: It loads.\n    retries: 1\n    safe_rerun: true\n    steps:\n      - goto: /\n")
      root = ChangeTestcasesEvidence.prepare(dir, "run-1")
      seen = []
      session = RecordingSession.new(root, fail_ids: [ "long/flaky" ])
      session.define_singleton_method(:run_function) do |code, **kw|
        seen << Dir.glob(File.join(root, "cases", "**", "frame-*.jpg")).size
        @fail_ids = [] if seen.size > 1
        super(code, **kw)
      end
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
      ChangeLaneTestcases.new(config, Ctx.new(nil, "https://a.example.org", session, [], false, root, "run-1", [ "video" ], 40),
                              grader: Grader.new("none"), video_runner: fake_ffmpeg, free_space: ->(_d) { 10_000 * MB }).run
      assert_equal [ 0, 0 ], seen
    end
  end

  # Two encodes and the cases still recording all draw on one pool of free
  # bytes above the reserve.
  def test_concurrent_encodes_cannot_both_spend_the_same_free_space
    Dir.mktmpdir do |dir|
      %w[a b].each do |name|
        FileUtils.mkdir_p(File.join(dir, name))
        File.binwrite(File.join(dir, name, "frame-a000001.jpg"), "x" * 1000)
      end
      gate = Queue.new
      runner = lambda do |argv|
        gate.pop
        work = argv[argv.index("--mount") + 1][/source=([^"]+)"/, 1]
        File.write(File.join(work, ChangeTestcasesVideo::OUT_NAME), "mp4")
        [ "", Status.new(true) ]
      end
      encoder = ChangeTestcasesVideo::Encoder.new(reserve: 0, runner: runner, free: -> { 3000 })
      %w[a b].each { |name| encoder.add(key: name, attempt_dir: File.join(dir, name), out: File.join(dir, "#{name}.mp4"), marks: []) }
      sleep 0.2
      2.times { gate << true }
      statuses = encoder.finish.values.map { |entry| entry["status"] }.sort
      assert_equal %w[failed ok], statuses
    end
  end

  def test_a_resumed_segment_records_only_what_is_left_of_the_share
    lane = ChangeLaneTestcases.allocate
    lane.instance_variable_set(:@encoder, Object.new)
    lane.instance_variable_set(:@video_bytes, 4 * MB)
    item = Struct.new(:qualified_id, :acceptance).new("s/c", "ok")
    assert_equal 3 * MB, lane.send(:video_js, item, MB)[:maxBytes]
    assert_nil lane.send(:video_js, item, 4 * MB)
  end
end
