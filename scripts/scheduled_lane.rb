#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'securerandom'
require 'shellwords'
require_relative 'scheduled_lane/command_runner'
require_relative 'scheduled_lane/lane_config'
require_relative 'scheduled_lane/lane_result'
require_relative 'scheduled_lane/lane_run'
require_relative 'scheduled_lane/flag_matrix'
require_relative 'scheduled_lane/sinks'

# Runs the scheduled lanes a repo declares in its CHANGE file (the top-level
# scheduled_lanes list, see skills/change/reference/CHANGE-frontmatter-spec.md).
#
#   scheduled_lane.rb run --config CHANGE.md --lane <id> [--ref REF] [--matrix off|touched]
#       [--env ENV] [--release-tag TAG] [--keys a,b] [--receipt ID]
#       [--job-timeout-minutes N] [--out FILE] [--dry-run]
#   scheduled_lane.rb report-infra --config CHANGE.md --lane <id> --reason TEXT [--ref REF] [--env ENV] [--release-tag TAG]
#   scheduled_lane.rb recover --config CHANGE.md --lane <id> --env ENV --receipt ID
#
# Exit codes: 0 pass, 1 fail, 2 usage or config error, 3 pass whose sinks failed.
module ScheduledLane
  class Cli
    RESULT_SCHEMA = 'cf-scheduled-lane-result/1'
    DEFAULT_OUT = 'scheduled-lane-result.json'
    DEFAULT_ENV = 'staging'
    TAG_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}
    COMMANDS = %w[run report-infra recover].freeze

    def self.main(argv) = exit(new.call(argv))

    def initialize(out: $stdout, err: $stderr, runner: nil, gh: GhClient.new, environ: ENV, workdir: Dir.pwd)
      @out = out
      @err = err
      @environ = environ
      @workdir = workdir
      @runner = runner || CommandRunner.new(chdir: workdir)
      @gh = gh
    end

    def call(argv)
      command = argv.first
      return usage("commands: #{COMMANDS.join(', ')}") unless COMMANDS.include?(command)

      opts = parse(argv.drop(1))
      lane = LaneConfig.find(opts.fetch(:config), opts.fetch(:lane))
      send(command.tr('-', '_'), lane, opts)
    rescue OptionParser::ParseError, KeyError => e
      usage(e.is_a?(KeyError) ? "missing required option: #{e.key.to_s.tr('_', '-')}" : e.message)
    rescue ConfigError => e
      usage(e.message)
    end

    private

    def parse(args)
      opts = { env: DEFAULT_ENV, matrix: 'off', ref: 'main', out: DEFAULT_OUT }
      OptionParser.new do |o|
        o.on('--config PATH') { |v| opts[:config] = v }
        o.on('--lane ID') { |v| opts[:lane] = v }
        o.on('--ref REF') { |v| opts[:ref] = v.to_s.empty? ? 'main' : v }
        o.on('--matrix MODE', %w[off touched]) { |v| opts[:matrix] = v }
        o.on('--env ENV') { |v| opts[:env] = v }
        o.on('--release-tag TAG') { |v| opts[:release_tag] = v unless v.to_s.empty? }
        o.on('--keys LIST') { |v| opts[:keys] = v.split(/[,\s]+/).reject(&:empty?).uniq }
        o.on('--receipt ID') { |v| opts[:receipt] = v }
        o.on('--job-timeout-minutes N', Integer) { |v| opts[:job_timeout] = v }
        o.on('--out FILE') { |v| opts[:out] = v }
        o.on('--reason TEXT') { |v| opts[:reason] = v }
        o.on('--dry-run') { opts[:dry_run] = true }
      end.parse!(args)
      opts
    end

    def usage(message)
      @err.puts("scheduled_lane: #{message}")
      2
    end

    # --- run ----------------------------------------------------------------

    def run(lane, opts)
      raise ConfigError, "lane '#{lane.id}' does not declare matrix mode touched-one-at-a-time" if opts[:matrix] == 'touched' && !lane.matrix_touched?
      raise ConfigError, "release tag #{opts[:release_tag].inspect} is not a plain tag name" if opts[:release_tag] && !opts[:release_tag].match?(TAG_PATTERN)
      return dry_run(lane, opts) if opts[:dry_run]

      base = base_run_id
      lane_run = build_lane_run(lane, opts, base)
      report = opts[:matrix] == 'touched' ? matrix_report(lane, opts, base, lane_run) : single_report(lane, opts, base, lane_run)
      finish(lane, opts, report)
    end

    def build_lane_run(lane, opts, base)
      LaneRun.new(lane: lane, runner: @runner, base_run_id: base, env_name: opts[:env], ref: opts[:ref], workdir: @workdir,
                  release: release(opts[:release_tag]), scrub: scrub(lane))
    end

    def single_report(lane, opts, base, lane_run)
      detection = detect(lane, opts, base)
      return detection if detection

      iteration = lane_run.call(0)
      build_report(lane, opts, base, status: iteration.verdict.status, failure_class: iteration.verdict.failure_class,
                                     notes: iteration.verdict.notes, iterations: [ iteration ])
    end

    # Nightly detection: a lane that declares a matrix reads the ledger and the
    # on-list even with --matrix off, and flips nothing.
    def detect(lane, opts, base)
      return nil unless lane.matrix_declared? && lane.detection_ready?

      found = FlagMatrix.new(lane: lane, runner: @runner, env_name: opts[:env], run_id: base, environ: @environ).detect
      return nil if found.pass?

      build_report(lane, opts, base, status: found.status, failure_class: found.failure_class, notes: found.notes, rows: found.rows)
    end

    def matrix_report(lane, opts, base, lane_run)
      matrix = FlagMatrix.new(lane: lane, runner: @runner, env_name: opts[:env], run_lane: lane_run.method(:call), receipt: opts[:receipt],
                              job_timeout_minutes: opts[:job_timeout], run_id: base, environ: @environ)
      found = matrix.run(opts[:keys] || [])
      build_report(lane, opts, base, status: found.status, failure_class: found.failure_class, notes: found.notes,
                                     rows: found.rows, iterations: found.iterations, stuck: found.stuck_flag)
    end

    # --- report-infra and recover -------------------------------------------

    def report_infra(lane, opts)
      reason = opts[:reason].to_s.strip
      raise ConfigError, 'report-infra needs --reason' if reason.empty?

      report = build_report(lane, opts, base_run_id, status: 'fail', failure_class: 'infra', notes: [ reason ])
      finish(lane, opts, report)
    end

    def recover(lane, opts)
      raise ConfigError, "lane '#{lane.id}' declares no matrix adapters" unless lane.matrix_declared? && lane.detection_ready?

      base = base_run_id
      found = FlagMatrix.new(lane: lane, runner: @runner, env_name: opts[:env], receipt: opts[:receipt], run_id: base, environ: @environ).recover
      report = build_report(lane, opts, base, status: found.status, failure_class: found.failure_class, notes: found.notes,
                                              rows: found.rows, stuck: found.stuck_flag)
      return finish(lane, opts, report) unless found.pass?

      print_report(report)
      0
    end

    # --- report assembly ------------------------------------------------------

    def build_report(lane, opts, base, status:, failure_class:, notes:, iterations: [], rows: [], stuck: nil)
      notes += [ "stuck flag: #{stuck}" ] if stuck
      Report.new(lane_id: lane.id, status: status, failure_class: failure_class, label: iterations.filter_map(&:label).first,
                 notes: notes, ref: opts[:ref], env: opts[:env], release_tag: opts[:release_tag], run_id: base,
                 deployed_sha: iterations.reverse.filter_map(&:deployed_sha_after).first, rows: rows,
                 cases: iterations.flat_map { |iteration| iteration.verdict.cases }, run_url: run_url, iterations: iterations,
                 release_sha: release(opts[:release_tag])&.fetch(:sha))
    end

    # Writes the result file, runs the sinks, prints, and returns the exit code.
    def finish(lane, opts, report)
      write_result(opts[:out], report)
      errors = Sinks.report_all(Sinks.build(lane, gh: @gh, runner: @runner), report)
      errors.each { |error| @err.puts("scheduled_lane: sink error: #{error}") }
      print_report(report)
      return 1 unless report.pass?

      errors.empty? ? 0 : 3
    end

    def print_report(report)
      @out.puts("lane #{report.lane_id}: #{report.status}#{report.failure_class ? " (#{report.failure_class})" : ''}")
      @out.puts(report.label) if report.label
      report.notes.each { |note| @out.puts("  #{note}") }
    end

    def write_result(path, report)
      iterations = report.iterations
      doc = { 'schema' => RESULT_SCHEMA, 'lane' => report.lane_id, 'ref' => report.ref, 'env' => report.env, 'release_tag' => report.release_tag,
              'release_sha' => report.release_sha, 'deployed_sha' => report.deployed_sha, 'run_id' => report.run_id, 'status' => report.status,
              'class' => report.failure_class, 'label' => report.label, 'ref_mismatch' => iterations.any?(&:ref_mismatch),
              'sha_moved' => iterations.any?(&:sha_moved), 'notes' => report.notes, 'matrix_rows' => report.rows,
              'iterations' => iterations.map(&:to_h) }
      File.write(File.expand_path(path, @workdir), "#{JSON.pretty_generate(doc)}\n")
    rescue SystemCallError => e
      @err.puts("scheduled_lane: could not write #{path}: #{e.message}")
    end

    # --- helpers --------------------------------------------------------------

    def base_run_id
      @base_run_id ||= if @environ['GITHUB_RUN_ID']
        "#{@environ['GITHUB_RUN_ID']}-#{@environ.fetch('GITHUB_RUN_ATTEMPT', '1')}"
      else
        "local-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(3)}"
      end
    end

    def run_url
      return nil unless @environ['GITHUB_RUN_ID'] && @environ['GITHUB_REPOSITORY']

      "#{@environ.fetch('GITHUB_SERVER_URL', 'https://github.com')}/#{@environ['GITHUB_REPOSITORY']}/actions/runs/#{@environ['GITHUB_RUN_ID']}"
    end

    # { tag:, sha: } for a release tag (sha nil when it does not resolve), else nil.
    def release(tag)
      return nil unless tag

      @releases ||= {}
      @releases[tag] ||= begin
        outcome = @runner.call("git rev-parse --verify --quiet #{Shellwords.escape("#{tag}^{commit}")}")
        { tag: tag, sha: outcome.ok? ? outcome.stdout.strip : nil }
      end
    end

    # Adapter and lane commands never see the ledger's write credential.
    def scrub(lane)
      cred = lane.matrix['ledger_credential_env']
      cred ? { cred => nil } : {}
    end

    # --- dry run ----------------------------------------------------------------

    def dry_run(lane, opts)
      matrix = lane.matrix
      @out.puts("dry run: nothing is executed except touched_cmd when --matrix touched")
      @out.puts("lane: #{lane.id}")
      @out.puts("run: #{lane.run}")
      @out.puts("result_file: #{lane.result_file} (per run: #{lane.result_path('<iteration>')})")
      @out.puts("timeout: #{lane.timeout_minutes} min")
      @out.puts("ref: #{opts[:ref]}  env: #{opts[:env]}  release_tag: #{opts[:release_tag] || '-'}")
      @out.puts("deployed_sha_cmd: #{lane.deployed_sha_cmd || '-'}")
      @out.puts("matrix: #{opts[:matrix]} (declared mode: #{matrix['mode'] || 'none'})")
      @out.puts("sinks: #{lane.sinks.map { |sink| sink['type'] }.join(', ').then { |text| text.empty? ? '-' : text }}")
      dry_run_matrix(lane, opts) if opts[:matrix] == 'touched'
      0
    end

    def dry_run_matrix(lane, opts)
      matrix = lane.matrix
      @out.puts("forbidden envs: #{lane.forbidden_envs.join(', ')}")
      @out.puts("max_flags: #{matrix['max_flags']}  settle: #{matrix['settle_seconds']}s  revert headroom: #{matrix['revert_headroom_seconds']}s")
      @out.puts("lock_group: #{matrix['lock_group']}")
      outcome = @runner.call(LaneConfig.fill(matrix['touched_cmd'], env: opts[:env]))
      return @out.puts("touched_cmd failed: #{outcome.summary}") unless outcome.ok?

      keys = outcome.stdout.lines.map(&:strip).reject(&:empty?)
      @out.puts("touched flags (#{keys.length}): #{keys.empty? ? '-' : keys.join(', ')}")
    end
  end
end

ScheduledLane::Cli.main(ARGV) if $PROGRAM_NAME == __FILE__
