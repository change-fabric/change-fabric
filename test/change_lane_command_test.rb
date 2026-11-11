# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/change_run"
require_relative "../scripts/change_lane_command"
require_relative "../scripts/change_trust"
require_relative "../scripts/change_artifact_publish"

# The command lane with a fake runner: nothing here spawns a shell, reads git,
# or writes outside temp directories.
class ChangeLaneCommandTest < Minitest::Test
  Verdict = Struct.new(:trusted) do
    def trusted?(step) = trusted.nil? || trusted.include?(step)
    def refusal(step) = "refusing to run #{step}: its definition differs from origin/main"
  end

  class FakeRunner
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def run(cmd, env:, chdir:, timeout: nil)
      @calls << { cmd: cmd, env: env, chdir: chdir, timeout: timeout }
      @results.size > 1 ? @results.shift : @results.first
    end
  end

  class FakeMedia
    attr_reader :files

    def initialize = @files = []
    def add_command_file(command:, relative:, source:) = @files << [ command, relative, File.read(source) ]
  end

  def setup
    @repo = Dir.mktmpdir
    @desktop = Dir.mktmpdir
    @logs = []
  end

  def teardown
    FileUtils.remove_entry(@repo)
    FileUtils.remove_entry(@desktop)
  end

  def result(code, output: "", timed_out: false)
    ChangeProcess::Result.new(status: code.zero? && !timed_out ? :pass : :fail, exit_code: code, output: output,
                              timed_out: timed_out, duration: 1.5)
  end

  def context(profile: nil, trust: Verdict.new(nil), media: nil, env_file_values: {}, step_prefix: "")
    ChangeRun::Context.new(target_url: "http://app", health_url: "http://app/health", run_id: "r1", profile: profile,
                           trust: trust, step_prefix: step_prefix, env_file_values: env_file_values, media: media,
                           logger: ->(message) { @logs << message })
  end

  def lane(entries, runner, **ctx)
    config = ChangeConfig::LaneConfig.new("command", { "enabled" => true, "commands" => entries }, @repo)
    ChangeLaneCommand.new(config, context(**ctx), runner: runner, desktop: @desktop)
  end

  def entry(**fields) = { "name" => "itest", "run" => "bin/itest", "timeout_seconds" => 60 }.merge(fields.transform_keys(&:to_s))

  def test_exit_zero_passes
    runner = FakeRunner.new(result(0, output: "ok\n"))
    finding = lane([ entry ], runner).run.first
    assert_equal "pass", finding.status
    assert_equal "itest", finding.check
    assert_match(/exit 0 in 1.5s/, finding.detail)
    assert_equal @repo, runner.calls.first[:chdir]
    assert_equal 60, runner.calls.first[:timeout]
    assert_equal "r1", runner.calls.first[:env]["CF_CHANGE_RUN_ID"]
  end

  def test_nonzero_exit_fails_high
    finding = lane([ entry ], FakeRunner.new(result(3, output: "boom\n"))).run.first
    assert_equal "fail", finding.status
    assert_equal "high", finding.severity
    assert_match(/exit 3 in 1.5s\nboom/, finding.detail)
  end

  def test_timeout_is_named
    finding = lane([ entry ], FakeRunner.new(result(0, timed_out: true))).run.first
    assert_equal "fail", finding.status
    assert_match(/timed out after 60s; process group killed/, finding.detail)
  end

  def test_per_entry_retries_mark_a_late_pass_flaky
    runner = FakeRunner.new(result(1), result(0))
    finding = lane([ entry(retries: 2) ], runner).run.first
    assert_equal "pass", finding.status
    assert_equal 2, finding.attempts
    assert finding.flaky
    assert_equal 2, runner.calls.size
  end

  def test_retries_stop_at_the_budget
    runner = FakeRunner.new(result(1))
    finding = lane([ entry(retries: 1) ], runner).run.first
    assert_equal "fail", finding.status
    assert_equal 2, finding.attempts
    refute finding.flaky
  end

  def test_profile_filter_skips_on_an_unprofiled_run
    runner = FakeRunner.new(result(0))
    finding = lane([ entry(profiles: %w[staging]) ], runner).run.first
    assert_equal "pass", finding.status
    assert_equal "skipped: profiles [staging] do not include unprofiled", finding.detail
    assert_empty runner.calls
  end

  def test_profile_filter_skips_another_profile_and_runs_its_own
    runner = FakeRunner.new(result(0))
    findings = lane([ entry(profiles: %w[staging]), entry(name: "smoke", profiles: %w[production]) ], runner,
                    profile: "production").run
    assert_match(/do not include production/, findings.first.detail)
    assert_match(/exit 0/, findings.last.detail)
    assert_equal 1, runner.calls.size
  end

  def test_untrusted_entry_is_refused_and_others_still_run
    runner = FakeRunner.new(result(0))
    findings = lane([ entry, entry(name: "smoke") ], runner, trust: Verdict.new(%w[command:smoke])).run
    assert_equal "fail", findings.first.status
    assert_match(/refusing to run command:itest/, findings.first.detail)
    assert_equal "pass", findings.last.status
    assert_equal [ "bin/itest" ], runner.calls.map { |call| call[:cmd] }
  end

  def test_missing_declared_env_fails_without_running
    runner = FakeRunner.new(result(0))
    finding = lane([ entry(env: %w[CF_LANE_TEST_MISSING_A CF_LANE_TEST_MISSING_B]) ], runner).run.first
    assert_equal "fail", finding.status
    assert_equal "missing declared env: CF_LANE_TEST_MISSING_A, CF_LANE_TEST_MISSING_B", finding.detail
    assert_empty runner.calls
  end

  def test_declared_values_are_masked_everywhere
    output = "token=s3cret-value\n"
    subject = lane([ entry(env: %w[CF_LANE_TOKEN], run: "bin/itest s3cret-value") ], FakeRunner.new(result(1, output: output)),
                   env_file_values: { "CF_LANE_TOKEN" => "s3cret-value" })
    finding = subject.run.first
    [ finding.detail, finding.target, subject.report_section, File.read(finding.location) ].each do |text|
      refute_includes text, "s3cret-value"
      assert_includes text, "***CF_LANE_TOKEN***"
    end
    assert_equal File.join(@desktop, "change-r1-command", "itest.log"), finding.location
  end

  def test_non_ascii_values_in_raw_output_are_masked_without_raising
    output = "token=sëcret\n".b
    finding = lane([ entry(env: %w[CF_LANE_TOKEN]) ], FakeRunner.new(result(0, output: output)),
                   env_file_values: { "CF_LANE_TOKEN" => "sëcret" }).run.first
    assert_equal "pass", finding.status
    assert_includes finding.detail, "token=***CF_LANE_TOKEN***"
  end

  def test_artifacts_are_copied_masked_with_a_warn_for_an_empty_glob
    FileUtils.mkdir_p(File.join(@repo, "tmp/itest"))
    File.write(File.join(@repo, "tmp/itest/junit.xml"), "<x>s3cret-value</x>")
    subject = lane([ entry(env: %w[CF_LANE_TOKEN], artifacts: [ "tmp/itest/*.xml", "none/*.log" ]) ],
                   FakeRunner.new(result(0)), env_file_values: { "CF_LANE_TOKEN" => "s3cret-value" })
    subject.run
    copied = File.join(@desktop, "change-r1-command", "itest", "artifacts", "tmp/itest/junit.xml")
    assert_equal "<x>***CF_LANE_TOKEN***</x>", File.read(copied)
    assert_match(/warn: artifact glob none\/\*\.log matched nothing/, subject.report_section)
  end

  def test_an_artifact_symlinked_outside_the_repo_is_not_copied
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret.txt"), "host-secret")
      File.symlink(File.join(outside, "secret.txt"), File.join(@repo, "leak.txt"))
      media = FakeMedia.new
      subject = lane([ entry(artifacts: [ "*.txt" ]) ], FakeRunner.new(result(0)), media: media)
      subject.run
      refute File.exist?(File.join(@desktop, "change-r1-command", "itest", "artifacts", "leak.txt"))
      assert_match(/artifact leak\.txt resolves outside the repository; not copied/, subject.report_section)
      refute(media.files.any? { |file| file.last.include?("host-secret") })
    end
  end

  def test_output_directory_is_namespaced_by_app_and_profile
    finding = lane([ entry ], FakeRunner.new(result(0)), step_prefix: "web/", profile: "staging").run.first
    assert_equal File.join(@desktop, "change-r1-web-staging-command", "itest.log"), finding.location
  end

  def test_dot_prefixed_artifacts_are_listed_for_upload
    Dir.mktmpdir do |root|
      source = File.join(@repo, "result.json")
      File.write(source, "{}")
      media = ChangeMedia.new(root)
      media.add_command_file(command: "coverage", relative: "artifacts/.nyc_output/result.json", source: source)
      assert_equal %w[commands/coverage/artifacts/.nyc_output/result.json], media.files
      publisher = ChangeArtifactPublish.new(bundle_dir: root, artifacts: nil)
      assert_equal %w[commands/coverage/artifacts/.nyc_output/result.json],
                   publisher.send(:declared_files).map { |file| file["path"] }
    end
  end

  def test_changing_boot_env_file_changes_command_digests
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      digest_for = lambda do |env_file|
        File.write(path, "---\nchange_config:\n  boot: { env_file: #{env_file} }\n  lanes:\n    command:\n" \
                         "      commands: [{ name: cleanup, run: bin/cleanup, timeout_seconds: 60 }]\n---\n")
        ChangeTrust.step_digests(ChangeConfig.load(path))["command:cleanup"]
      end
      refute_equal digest_for.call(".env.staging"), digest_for.call(".env.production")
    end
  end

  def test_media_keeps_distinct_command_names_apart
    Dir.mktmpdir do |root|
      source = File.join(@repo, "out.txt")
      File.write(source, "x")
      media = ChangeMedia.new(root)
      media.add_command_file(command: "unit_test", relative: "out.txt", source: source)
      media.add_command_file(command: "unit-test", relative: "out.txt", source: source)
      assert_equal %w[commands/unit-test/out.txt commands/unit_test/out.txt], media.files
    end
  end

  def test_media_sink_receives_transcript_and_artifacts
    File.write(File.join(@repo, "out.txt"), "result")
    media = FakeMedia.new
    lane([ entry(artifacts: [ "out.txt" ]) ], FakeRunner.new(result(0, output: "log\n")), media: media).run
    assert_equal [ [ "itest", "itest.log", "log\n" ], [ "itest", "artifacts/out.txt", "result" ] ], media.files
  end

  def test_report_section_lists_each_entry
    subject = lane([ entry, entry(name: "smoke", profiles: %w[staging]) ], FakeRunner.new(result(0, output: "fine\n")))
    subject.run
    section = subject.report_section
    assert_match(/## Command lane/, section)
    assert_match(/\| itest \| pass \| 0 \| 1.5s \| 1 \|/, section)
    assert_match(/\| smoke \| skipped \|/, section)
    assert_match(/```\nfine\n```/, section)
  end

  def test_lane_level_retry_loop_does_not_rerun_the_lane
    run = ChangeRun.new(%w[command])
    config = ChangeConfig::LaneConfig.new("command", { "retries" => 3, "commands" => [ entry ] }, @repo)
    findings, instance = capture_stderr do
      run.send(:run_lane, "command", config, context(trust: Verdict.new([])))
    end
    assert_equal 1, findings.size
    assert_equal 1, findings.first.attempts
    assert instance.self_retrying?
  end

  def test_command_is_an_accepted_scope
    assert_equal "command", ChangeRun.new(%w[command]).send(:parse_args, %w[command]).scope
  end

  def test_step_digests_include_entries_that_apply_to_the_profile
    Dir.mktmpdir do |root|
      path = File.join(root, "CHANGE.md")
      File.write(path, <<~MD)
        ---
        change_config:
          profiles:
            staging: {}
            production: {}
          default_profile: staging
          lanes:
            command:
              commands:
                - { name: itest, run: bin/itest, timeout_seconds: 60 }
                - { name: prod, run: bin/prod, timeout_seconds: 60, profiles: [production] }
        ---
      MD
      digests = ChangeTrust.step_digests(ChangeConfig.load(path))
      assert_equal [ "command:itest" ], digests.keys
      assert_match(/\Asha256:/, digests["command:itest"])
    end
  end

  private

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
