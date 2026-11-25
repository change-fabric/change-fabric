# frozen_string_literal: true

require 'fileutils'
require_relative 'lane_config'
require_relative 'lane_result'

module ScheduledLane
  # One graded run of a lane command: its own run id and result path, the
  # deployed SHA read immediately before and after, and the verdict that
  # results from the result file, the exit code, a moved SHA and a release tag
  # that is not what is deployed.
  class LaneRun
    Iteration = Struct.new(:iteration, :run_id, :result_path, :verdict, :deployed_sha_before, :deployed_sha_after,
                           :sha_moved, :ref_mismatch, :label, keyword_init: true) do
      def to_h
        { 'iteration' => iteration, 'run_id' => run_id, 'result_path' => result_path, 'deployed_sha_before' => deployed_sha_before,
          'deployed_sha_after' => deployed_sha_after, 'sha_moved' => sha_moved, 'ref_mismatch' => ref_mismatch,
          'label' => label }.merge(verdict.to_h)
      end
    end

    # `release` is nil, or { tag:, sha: } with sha nil when the tag did not resolve.
    def initialize(lane:, runner:, base_run_id:, env_name:, ref:, workdir:, release: nil, scrub: {})
      @lane = lane
      @runner = runner
      @base_run_id = base_run_id
      @env_name = env_name
      @ref = ref
      @workdir = workdir
      @release = release
      @scrub = scrub
    end

    def call(iteration)
      run_id = "#{@base_run_id}-#{iteration}"
      path = @lane.result_path(iteration)
      absolute = File.expand_path(path, @workdir)
      FileUtils.mkdir_p(File.dirname(absolute))
      FileUtils.rm_f(absolute)

      before = deployed_sha
      outcome = @runner.call(@lane.run, env: lane_env(run_id, absolute), timeout: @lane.timeout_seconds)
      after = deployed_sha
      verdict = LaneResult.classify(outcome, absolute, run_id)
      build(iteration, run_id, path, verdict, before, after)
    end

    private

    def lane_env(run_id, result_path)
    @scrub.merge('CF_LANE_RUN_ID' => run_id, 'CF_LANE_RESULT_FILE' => result_path, 'CF_LANE_REF' => @ref.to_s,
                 'CF_LANE_ENV' => @env_name.to_s)
    end

    # [sha, nil] or [nil, problem]; [nil, nil] when the lane declares no command.
    def deployed_sha
    return [ nil, nil ] unless @lane.deployed_sha_cmd

    outcome = @runner.call(LaneConfig.fill(@lane.deployed_sha_cmd, env: @env_name), env: @scrub)
    sha = outcome.stdout.to_s.lines.first.to_s.strip
    return [ nil, "deployed_sha_cmd failed: #{outcome.summary}" ] if !outcome.ok? || sha.empty?

    [ sha, nil ]
    end

    def build(iteration, run_id, path, verdict, before, after)
    problem = sha_problem(before, after)
    row = Iteration.new(iteration: iteration, run_id: run_id, result_path: path, verdict: verdict,
                        deployed_sha_before: before[0], deployed_sha_after: after[0], sha_moved: problem == :moved,
                        ref_mismatch: false, label: nil)
    apply_sha(row, problem, before[1] || after[1])
    apply_release(row)
    row
    end

    def sha_problem(before, after)
    return nil unless @lane.deployed_sha_cmd
    return :unreadable if before[1] || after[1]

    before[0] == after[0] ? nil : :moved
    end

    def apply_sha(row, problem, detail)
    return unless problem

    note = problem == :moved ? "deployed SHA moved during the run (#{row.deployed_sha_before} -> #{row.deployed_sha_after})" : detail
    row.verdict = Verdict.new(status: 'fail', failure_class: 'infra', notes: [ note ] + row.verdict.notes, cases: row.verdict.cases)
    end

    # With a release tag, the deployed SHA must be the tag's SHA. A run that
    # cannot show that fails outright: diligence on the wrong build is no
    # diligence.
    def apply_release(row)
    return unless @release

    tag = @release[:tag]
    sha = stable_sha(row)
    if @release[:sha].nil?
      fail_release(row, nil, "release tag #{tag} did not resolve to a commit")
    elsif sha.nil?
      row.label = "deployed SHA unknown, not #{tag}"
      fail_release(row, true, "deployed SHA could not be verified against #{tag}")
    elsif !same_sha?(sha, @release[:sha])
      row.label = "#{@env_name} at #{sha[0, 12]}, not #{tag}"
      fail_release(row, true, row.label)
    end
    end

    def stable_sha(row)
    row.deployed_sha_before if row.deployed_sha_before && row.deployed_sha_before == row.deployed_sha_after
    end

    def same_sha?(left, right)
    short = [ left.length, right.length ].min
    short >= 7 && left[0, short].casecmp?(right[0, short])
    end

    def fail_release(row, mismatch, note)
    row.ref_mismatch = true if mismatch
    row.verdict = Verdict.new(status: 'fail', failure_class: row.verdict.failure_class || 'infra',
                              notes: [ note ] + row.verdict.notes, cases: row.verdict.cases)
    end
  end
end
