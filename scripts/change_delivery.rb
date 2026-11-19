#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'time'
require 'timeout'
require 'yaml'
require_relative 'change_flags_fixture'
require_relative 'change_flags_protocol'
require_relative 'change_frontmatter'
require_relative 'change_verdict'

# Progressive-delivery commands.
#
#   validate-verdict <file> [--now ISO] [--max-age S]
#   flags <rollout> <get|set_cohort|disable|enable> [--config CHANGE.md] [--cohort C]
#         [--expected-revision N] [--fencing-token N] [--env ENV]
#   conformance [--traces DIR] -- <controller argv...>
#
# `flags` dispatches one cf.flags/1 request to the adapter the rollout names. It
# never holds production credentials: a `kind: fixture` adapter keeps JSON
# state in a temp file, and a `kind: command` adapter is the consumer's own
# CLI, which in production runs inside the consumer's worker (cf then only
# reaches it for staging and dry runs). The admin-token limit stands: the gates
# rest on hooks, not on token scope.
#
# `conformance` replays test/fixtures/delivery/traces/*.json against a
# controller command: the trace (without `expect`) on stdin, a
# {"transitions": [...]} object on stdout. Exit 0 only when every trace matches.
module ChangeDelivery
  TRACES_DIR = File.expand_path('../test/fixtures/delivery/traces', __dir__)
  TRANSITION_KEYS = %w[step verdict action stage].freeze
  FLAG_OPTIONS = %w[cohort expected_revision fencing_token env config].freeze

  module_function

  def run(argv, stdout: $stdout, stderr: $stderr)
    command, *rest = argv
    case command
    when 'validate-verdict' then validate_verdict(rest, stdout, stderr)
    when 'flags' then flags(rest, stdout, stderr)
    when 'conformance' then conformance(rest, stdout, stderr)
    else
      stderr.puts 'usage: change_delivery.rb validate-verdict <file> | flags <rollout> <op> | conformance [--traces DIR] -- <controller argv>'
      2
    end
  end

  # --- validate-verdict -----------------------------------------------------

  def validate_verdict(args, stdout, stderr)
    options = { now: Time.now.utc, max_age: ChangeVerdict::MAX_TELEMETRY_AGE_S }
    parser = OptionParser.new do |o|
      o.on('--now ISO') { |v| options[:now] = Time.iso8601(v) }
      o.on('--max-age SECONDS', Integer) { |v| options[:max_age] = v }
    end
    files = parser.parse(args)
    return usage(stderr, 'validate-verdict <file>') unless files.length == 1

    record = JSON.parse(File.read(files.first))
    protocol = record.is_a?(Hash) ? record['protocol'] : nil
    errors = protocol == ChangeVerdict::HEARTBEAT_PROTOCOL ? ChangeVerdict.heartbeat_errors(record) : ChangeVerdict.verdict_errors(record, max_age_s: options[:max_age])
    stdout.puts(errors.empty? ? "#{protocol || 'record'} OK: #{files.first}" : errors.map { |e| "error: #{e}" })
    errors.empty? ? 0 : 1
  rescue JSON::ParserError, ArgumentError, Errno::ENOENT => e
    stderr.puts "[delivery] #{e.message}"
    2
  end

  # --- flags ----------------------------------------------------------------

  def flags(args, stdout, stderr)
    options = {}
    parser = OptionParser.new do |o|
      FLAG_OPTIONS.each { |name| o.on("--#{name.tr('_', '-')} VALUE") { |v| options[name.to_sym] = v } }
    end
    rollout, op = parser.parse(args)
    return usage(stderr, 'flags <rollout> <get|set_cohort|disable|enable>') unless rollout && op

    adapter, flag, env = resolve_adapter(rollout, options.fetch(:config, 'CHANGE.md'), options[:env])
    request = build_request(op, flag, env, options)
    reply = adapter.call(request)
    stdout.puts JSON.pretty_generate(reply)
    reply['ok'] ? 0 : 1
  rescue KeyError, ArgumentError, Errno::ENOENT, JSON::ParserError => e
    stderr.puts "[delivery] #{e.message}"
    2
  end

  def build_request(op, flag, env, options)
    { 'protocol' => ChangeFlagsProtocol::PROTOCOL, 'request_id' => SecureRandom.uuid, 'idempotency_key' => SecureRandom.uuid,
      'op' => op, 'flag' => flag, 'env' => env, 'expected_revision' => Integer(options.fetch(:expected_revision, '0')) }.tap do |request|
      request['cohort'] = options[:cohort] if options[:cohort]
      request['fencing_token'] = Integer(options[:fencing_token]) if options[:fencing_token]
    end
  end

  # Returns [callable, flag key, adapter env] for a rollout in CHANGE.md.
  def resolve_adapter(rollout, config_path, env_override)
    config = ChangeFrontmatter.parse_file(config_path).dig('change_config', 'delivery') || {}
    entry = config.dig('rollouts', rollout) or raise KeyError, "no rollout '#{rollout}' in #{config_path}"
    spec = config.dig('flags', entry['flags']) or raise KeyError, "rollout '#{rollout}' names no flags adapter"
    env = env_override || spec.dig('environments', entry['profile']) || entry['profile'].to_s
    [ adapter_for(spec, File.dirname(File.expand_path(config_path))), entry['flag'], env ]
  end

  def adapter_for(spec, root)
    case spec['kind']
    when 'fixture' then ChangeFlagsFixture.new(spec['path'] ? File.expand_path(spec['path'], root) : ChangeFlagsFixture.default_path)
    when 'command' then ->(request) { command_adapter(spec, root, request) }
    else raise ArgumentError, "unsupported flags adapter kind '#{spec['kind']}'"
    end
  end

  # One JSON request on stdin, one JSON reply on stdout, under timeout_s. A
  # failure is an `unavailable` reply, never an exception.
  def command_adapter(spec, root, request)
    cwd = spec['cwd'] == 'repo' || spec['cwd'].nil? ? root : File.expand_path(spec['cwd'], root)
    out, status = run_with_timeout(spec.fetch('argv'), JSON.generate(request), cwd, spec.fetch('timeout_s', 30))
    status.success? ? JSON.parse(out) : unavailable(request, "adapter exited #{status.exitstatus}")
  rescue Timeout::Error, JSON::ParserError, SystemCallError => e
    unavailable(request, "#{e.class}: #{e.message}")
  end

  # Runs argv with stdin_data, returning [stdout, status]. On timeout the whole
  # process group is killed and reaped before Timeout::Error is raised;
  # Timeout.timeout around Open3.capture2 would wait out a hung child.
  def run_with_timeout(argv, stdin_data, chdir, timeout_s)
    options = { pgroup: true }
    options[:chdir] = chdir if chdir
    Open3.popen2(*argv, **options) do |stdin, stdout, wait|
      writer = Thread.new { write_all(stdin, stdin_data) }
      reader = Thread.new { stdout.read }
      return [ reader.value, wait.value ] if wait.join(timeout_s)

      kill_group(wait.pid)
      wait.join
      raise Timeout::Error, "no exit within #{timeout_s}s"
    ensure
      writer&.kill
      reader&.kill
    end
  end

  def write_all(io, data)
    io.write(data)
  rescue Errno::EPIPE
    nil
  ensure
    io.close
  end

  def kill_group(pid)
    Process.kill('KILL', -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def unavailable(request, message)
    ChangeFlagsProtocol.reply_for(ChangeFlagsProtocol.initial_state, request, error: ChangeFlagsProtocol.error('unavailable', message))
  end

  # --- conformance ----------------------------------------------------------

  def conformance(args, stdout, stderr)
    split = args.index('--')
    return usage(stderr, 'conformance [--traces DIR] -- <controller argv...>') unless split && split < args.length - 1

    controller = args[(split + 1)..]
    dir = TRACES_DIR
    OptionParser.new { |o| o.on('--traces DIR') { |v| dir = v } }.parse!(args[0...split])
    files = Dir[File.join(dir, '*.json')].sort
    return usage(stderr, "no traces in #{dir}") if files.empty?

    failures = files.map { |file| replay(file, controller) }.compact
    files.each { |file| stdout.puts "#{failures.any? { |f| f.start_with?(File.basename(file)) } ? 'FAIL' : 'ok  '} #{File.basename(file)}" }
    failures.each { |failure| stdout.puts "  #{failure}" }
    stdout.puts "conformance: #{files.length - failures.length}/#{files.length} traces passed"
    failures.empty? ? 0 : 1
  end

  # Returns nil on a match, else a one-line description of the first mismatch.
  def replay(file, controller)
    trace = JSON.parse(File.read(file))
    out, status = run_with_timeout(controller, JSON.generate(trace.reject { |k, _| k == 'expect' }), nil, 60)
    name = File.basename(file)
    return "#{name}: controller exited #{status.exitstatus}" unless status.success?

    actual = JSON.parse(out)['transitions']
    return "#{name}: controller printed no transitions array" unless actual.is_a?(Array)

    mismatch(name, trace['expect'], actual)
  rescue JSON::ParserError, Timeout::Error, SystemCallError => e
    "#{File.basename(file)}: #{e.class}: #{e.message}"
  end

  def mismatch(name, expected, actual)
    return "#{name}: expected #{expected.length} transitions, got #{actual.length}" unless expected.length == actual.length

    expected.zip(actual).each do |want, got|
      TRANSITION_KEYS.each do |key|
        return "#{name}: step #{want['step']} #{key}: expected #{want[key].inspect}, got #{got.is_a?(Hash) ? got[key].inspect : got.inspect}" unless got.is_a?(Hash) && got[key] == want[key]
      end
    end
    nil
  end

  def usage(stderr, text)
    stderr.puts "usage: change_delivery.rb #{text}"
    2
  end
end

exit(ChangeDelivery.run(ARGV)) if $PROGRAM_NAME == __FILE__
