#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require_relative 'change_lane'
require_relative 'change_env'
require_relative 'change_findings'
require_relative 'change_process'
require_relative 'change_report'

# The command lane (0.17.0): a project's own checks (integration tests against
# a throwaway database container, a containerized e2e suite, test-data
# cleanup, a smoke test against a deployed environment) run on the host beside
# the dockerized audit lanes, each passing or failing on its exit code.
#
# Entries run in order, one at a time, since they may share a database
# container. Each entry runs only when trusted (its definition equals the base
# branch's, or a human approved it for this commit), with the minimal
# environment plus the names it declares, under its own timeout, retried up to
# its own `retries`. Declared values are masked in every line written: the
# finding, the report section, the Desktop transcript, copied text artifacts,
# and anything published through the media sink.
#
# Commands may start their own containers. They should name or label them
# with CF_CHANGE_RUN_ID and clean them up themselves: ChangeDocker.sweep only
# reaps cf-change-* resources.
class ChangeLaneCommand < ChangeLane
  LANE = 'command'
  TAIL_LINES = 40
  MAX_MASKED_ARTIFACT_BYTES = 5 * 1024 * 1024

  # One entry's run, kept for the report section after #run returns.
  Outcome = Struct.new(:name, :status, :exit_code, :duration, :attempts, :transcript, :tail, :note,
                       keyword_init: true)

  attr_reader :outcomes

  # `runner` stands in for ChangeProcess, `trust` for the run's ChangeTrust
  # verdict (the context's by default), and `desktop` for the report
  # directory, so a test never spawns a shell, reads git or writes to ~/Desktop.
  def initialize(config, context, runner: ChangeProcess, trust: nil, desktop: ChangeReport::DESKTOP)
    super(config, context)
    @runner = runner
    @trust = trust || context.trust
    @desktop = desktop
    @outcomes = []
  end

  def self_retrying? = true

  def run = entries.map { |entry| run_entry(entry) }

  def report_section
    lines = [ '## Command lane', '', '| Command | Status | Exit | Duration | Attempts | Transcript |',
              '| --- | --- | --- | --- | --- | --- |' ]
    @outcomes.each do |item|
      lines << "| #{item.name} | #{item.status} | #{item.exit_code || '-'} | #{item.duration ? "#{item.duration}s" : '-'} | " \
               "#{item.attempts || '-'} | #{item.transcript || '-'} |"
    end
    @outcomes.each do |item|
      lines.push('', "### #{item.name}", '')
      lines.push(item.note, '') if item.note
      lines.push('```', item.tail.to_s.chomp, '```') unless item.tail.to_s.empty?
    end
    "#{lines.join("\n")}\n"
  end

  private

  def entries = Array(@config['commands']).select { |entry| entry.is_a?(Hash) }

  def run_entry(entry)
    name = entry['name'].to_s
    return skip(entry, name) unless applies?(entry)

    step = "#{@context.step_prefix}command:#{name}"
    return refuse(name, entry, @trust.refusal(step)) unless @trust.trusted?(step)

    env = ChangeEnv.build(declared: Array(entry['env']), env_file_values: @context.env_file_values || {},
                          extra: run_env)
    execute(entry, name, env)
  rescue ChangeEnv::MissingVariables => e
    refuse(name, entry, "missing declared env: #{e.names.join(', ')}")
  end

  def applies?(entry) = entry['profiles'].nil? || Array(entry['profiles']).include?(@context.profile)

  def skip(entry, name)
    detail = "skipped: profiles [#{Array(entry['profiles']).join(', ')}] do not include #{@context.profile || 'unprofiled'}"
    @outcomes << Outcome.new(name: name, status: 'skipped', note: detail)
    Finding.new(lane: LANE, check: name, status: 'pass', severity: 'info', target: entry['run'].to_s, detail: detail)
  end

  def refuse(name, entry, detail)
    @context.log("[change] command #{name}: #{detail.lines.first.strip}")
    @outcomes << Outcome.new(name: name, status: 'fail', note: detail)
    Finding.new(lane: LANE, check: name, status: 'fail', severity: 'high', target: entry['run'].to_s, detail: detail)
  end

  def run_env
    {
      'CF_CHANGE_RUN_ID' => @context.run_id, 'CF_CHANGE_TARGET_URL' => @context.target_url,
      'CF_CHANGE_HEALTH_URL' => @context.health_url
    }
  end

  def execute(entry, name, env)
    mask = env.masker
    result, attempts = attempt(entry, name, env)
    tail = mask.call(result.output).lines.last(TAIL_LINES).join
    transcript = write_transcript(name, mask.call(result.output))
    notes = collect_artifacts(entry, name, mask)
    status = result.success? ? 'pass' : 'fail'
    @outcomes << Outcome.new(name: name, status: status, exit_code: result.exit_code, duration: result.duration,
                             attempts: attempts, transcript: transcript, tail: tail, note: notes)
    Finding.new(lane: LANE, check: name, status: status, severity: result.success? ? 'info' : 'high',
                target: mask.call(entry['run']), detail: "#{headline(result, entry)}\n#{tail}".strip,
                location: transcript, attempts: attempts, flaky: attempts > 1 && result.success?)
  end

  # Runs the entry up to 1 + its own `retries` times, stopping at the first
  # pass. The lane-wide retry loop never re-runs this lane (self_retrying?).
  def attempt(entry, name, env)
    budget = entry.fetch('retries', 0).to_i
    attempts = 0
    loop do
      attempts += 1
      @context.log("[change] command #{name}: attempt #{attempts}")
      result = @runner.run(entry['run'], env: env.env, chdir: @config.dir, timeout: entry['timeout_seconds'])
      return [ result, attempts ] if result.success? || attempts > budget
    end
  end

  def headline(result, entry)
    return "timed out after #{entry['timeout_seconds']}s; process group killed" if result.timed_out

    "exit #{result.exit_code} in #{result.duration}s"
  end

  # One directory per run, app and profile: a monorepo sweep or a --for-tag
  # sweep shares one run id, and two apps (or profiles) with a same-named
  # command must not overwrite each other's evidence.
  def out_dir
    parts = [ "change-#{@context.run_id}", @context.step_prefix.to_s.delete_suffix('/'), @context.profile, 'command' ]
    File.join(@desktop, parts.compact.reject(&:empty?).join('-'))
  end

  def write_transcript(name, text)
    FileUtils.mkdir_p(out_dir)
    path = File.join(out_dir, "#{name}.log")
    File.write(path, text)
    @context.media&.add_command_file(command: name, relative: "#{name}.log", source: path)
    path
  end

  # Copies every artifact glob match, preserving its repo-relative path, into
  # the Desktop sibling (and the media sink when present). A glob that matches
  # nothing is a note, not a failure. Text files are masked before the copy;
  # binary files are copied as they are and the note says so.
  def collect_artifacts(entry, name, mask)
    notes = []
    Array(entry['artifacts']).each do |glob|
      matches = Dir.glob(glob, base: @config.dir).select { |rel| File.file?(File.join(@config.dir, rel)) }
      notes << "warn: artifact glob #{glob} matched nothing" if matches.empty?
      matches.each { |rel| notes << copy_artifact(name, rel, mask) }
    end
    notes.compact.empty? ? nil : notes.compact.join("\n")
  end

  # A match is copied only when it, after following symlinks, is a file inside
  # the repository: a branch could otherwise point a trusted glob's match at a
  # secret elsewhere on the host, whose value no declared name would mask.
  def contained?(rel)
    root = File.realpath(@config.dir)
    File.realpath(File.join(@config.dir, rel)).start_with?("#{root}/")
  rescue SystemCallError
    false
  end

  def copy_artifact(name, rel, mask)
    artifacts_dir = File.join(out_dir, name, 'artifacts')
    dest = File.expand_path(rel, artifacts_dir)
    unless contained?(rel) && dest.start_with?("#{artifacts_dir}/")
      return "warn: artifact #{rel} resolves outside the repository; not copied"
    end

    source = File.join(@config.dir, rel)
    FileUtils.mkdir_p(File.dirname(dest))
    note = nil
    if masked_text?(source)
      File.write(dest, mask.call(File.read(source)))
    else
      FileUtils.cp(source, dest)
      note = "artifact #{rel} copied unmasked (binary or over 5 MB)"
    end
    @context.media&.add_command_file(command: name, relative: File.join('artifacts', rel), source: dest)
    note
  end

  def masked_text?(path)
    return false if File.size(path) > MAX_MASKED_ARTIFACT_BYTES

    File.read(path).force_encoding(Encoding::UTF_8).valid_encoding?
  end
end
