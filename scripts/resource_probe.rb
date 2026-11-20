# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require_relative 'cf_project_identity'
require_relative 'path_canon'
require_relative 'resource_fingerprint'
require_relative 'resource_gate'

# Learns what heavy commands cost, so the resource gate can size its need.
#
#   ruby scripts/resource_probe.rb probe <op> [--prereq OP]... -- <cmd...>
#   ruby scripts/resource_probe.rb benchmark <op> [<op>...]   (forced; only when invoked)
#   ruby scripts/resource_probe.rb show [--project DIR] [--json]
#
# `probe` runs the command with CF_PROBE_ACTIVE=1 (a nested probe just runs its
# command, so nothing wraps twice), samples process-tree RSS at about 1 Hz plus
# df/du (and Docker) deltas, and passes the child's exit status or signal
# through unchanged. Sampling is a lower bound: a spike shorter than the
# interval is missed. A profile is written only after a run that exits 0, so a
# command that dies early never records a misleadingly small peak.
#
# The profile lives at ~/.claude/cf/benchmarks/<slug>/profile.json, written
# under a lock. It holds op names, numbers, fingerprints, argv, a repo-relative
# cwd and prereq op names; Sanitize drops absolute paths and secrets.
module ResourceProbe
  VERSION = 1
  ACTIVE_ENV = 'CF_PROBE_ACTIVE'
  RAISE_RATIO = 1.25
  DECAY = 0.9
  SAMPLE_INTERVAL = 1.0
  FORWARDED_SIGNALS = %w[INT TERM HUP].freeze
  SECRET_FLAG = /\A--?[\w-]*(token|secret|password|passwd|apikey|api-key|key|auth|credential)[\w-]*\z/i
  SECRET_VALUE = %r{\A(sk-|ghp_|gho_|github_pat_|xox[abp]-|AKIA|AIza)|\A[A-Fa-f0-9]{32,}\z|\A(?=[A-Za-z0-9+_-]*\d)(?=[A-Za-z0-9+_-]*[A-Za-z])[A-Za-z0-9+_-]{40,}={0,2}\z}
  ENV_ASSIGN = /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m

  # How a new run changes a stored op: a peak more than 25% over the stored
  # value replaces it at once; otherwise the stored value decays slowly.
  module Drift
    FIELDS = %w[peak_rss_mb disk_delta_gb docker_mem_peak_mb docker_disk_delta_gb].freeze

    module_function

    def merge(old, fresh)
      return fresh.dup unless old

      fresh.merge(FIELDS.to_h { |f| [ f, blend(old[f].to_f, fresh[f].to_f) ] })
    end

    def blend(stored, new)
      return new if stored.zero? || new > stored * RAISE_RATIO

      [ new, stored * DECAY ].max.round(2)
    end
  end

  # Keeps absolute paths, env values and secrets out of what is stored.
  module Sanitize
    module_function

    # Returns [argv, changed?]. A path made repo-relative is not a change that
    # blocks a forced benchmark; a redaction is.
    def argv(args, root)
      redacted = false
      redact_next = false
      out = args.map do |arg|
        arg = arg.to_s
        if redact_next
          redact_next = false
          redacted = true
          next '<redacted>'
        end
        clean = token(arg, root)
        redact_next = arg.match?(SECRET_FLAG) && !arg.include?('=')
        redacted ||= clean.include?('<')
        clean
      end
      [ out, redacted ]
    end

    def token(arg, root)
      if !arg.start_with?('-') && (m = arg.match(ENV_ASSIGN))
        return "#{m[1]}=<redacted>"
      end
      return key_value(arg, root) if arg.start_with?('-') && arg.include?('=')
      return '<redacted>' if arg.match?(SECRET_VALUE)

      path(arg, root)
    end

    def key_value(arg, root)
      flag, value = arg.split('=', 2)
      return "#{flag}=<redacted>" if flag.match?(SECRET_FLAG) || value.match?(SECRET_VALUE)

      "#{flag}=#{path(value, root)}"
    end

    def path(arg, root)
      return arg unless arg.start_with?('/', '~')

      relative_to(arg, root) || '<path>'
    end

    def relative_to(arg, root)
      return nil if arg.start_with?('~')

      PathCanon.relative(arg, root)
    end

    def cwd(dir, root) = PathCanon.relative(dir, root) || '.'
  end

  # The profile file for one project, written under an exclusive lock.
  class Store
    def initialize(slug:, home: Dir.home)
      @dir = File.join(home, '.claude', 'cf', 'benchmarks', slug)
    end

    def path = File.join(@dir, 'profile.json')

    def read
      data = JSON.parse(File.read(path))
      data['ops'].is_a?(Hash) ? data : empty
    rescue SystemCallError, JSON::ParserError
      empty
    end

    def ops = read['ops']

    # Yields the stored op (or nil) and stores the returned entry.
    def update_op(name)
      locked do
        data = read
        data['version'] = VERSION
        data['ops'][name] = yield(data['ops'][name])
        write(data)
        data['ops'][name]
      end
    end

    private

    def empty = { 'version' => VERSION, 'ops' => {} }

    def locked
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.open(File.join(@dir, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def write(data)
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(data), perm: 0o600)
      File.rename(tmp, path)
    end
  end

  CAPTURE = ->(*argv) { Open3.capture2(*argv).first }

  # Default samplers. Tests inject fakes, so no test reads a real process.
  class TreeSampler
    def initialize(runner: CAPTURE) = @runner = runner

    # Total RSS in MB of pid and all its descendants (ps reports KB on macOS and Linux).
    def rss_mb(pid)
      rows = @runner.call('ps', '-axo', 'pid=,ppid=,rss=').lines.map { |l| l.split.map(&:to_i) }.select { |r| r.length == 3 }
      kids = rows.group_by { |r| r[1] }
      seen = {}
      stack = [ pid ]
      until stack.empty?
        cur = stack.pop
        next if seen[cur]

        seen[cur] = true
        (kids[cur] || []).each { |r| stack << r[0] }
      end
      rows.select { |r| seen[r[0]] }.sum { |r| r[2] } / 1024.0
    rescue SystemCallError
      0.0
    end
  end

  class DiskSampler
    def initialize(runner: CAPTURE) = @runner = runner

    # {free_gb:, used_gb:} for the repo volume (df) and the repo tree (du).
    def read(root)
      free_kb = @runner.call('df', '-Pk', root).lines.last.to_s.split[3].to_i
      used_kb = @runner.call('du', '-sk', root).split.first.to_i
      { free_gb: free_kb / ResourceGate::KB_PER_GB, used_gb: used_kb / ResourceGate::KB_PER_GB }
    rescue SystemCallError
      { free_gb: 0.0, used_gb: 0.0 }
    end
  end

  # Docker memory (sum of container MemUsage) and image plus build-cache size.
  # Any failure reads as zero: the numbers are a lower bound.
  class DockerSampler
    UNIT = { 'b' => 1.0 / (1024 * 1024), 'k' => 1.0 / 1024, 'm' => 1.0, 'g' => 1024.0, 't' => 1024.0 * 1024 }.freeze

    def initialize(runner: CAPTURE) = @runner = runner

    def mem_mb
      rows('docker', 'stats', '--no-stream', '--format', '{{json .}}').sum { |r| mb(r['MemUsage'].to_s.split('/').first) }
    rescue StandardError
      0.0
    end

    def disk_gb
      rows('docker', 'system', 'df', '--format', '{{json .}}').select { |r| [ 'Images', 'Build Cache' ].include?(r['Type']) }
                                                              .sum { |r| mb(r['Size']) } / 1024.0
    rescue StandardError
      0.0
    end

    private

    def rows(*cmd) = @runner.call(*cmd).lines.map(&:strip).reject(&:empty?).map { |l| JSON.parse(l) }

    def mb(text)
      m = text.to_s.strip.match(/\A([\d.]+)\s*([kKmMgGtT]?)i?[bB]\z/)
      m ? m[1].to_f * UNIT.fetch(m[2].empty? ? 'b' : m[2].downcase) : 0.0
    end
  end

  # Runs a command with sampling and returns the measurements and the status.
  class Runner
    def initialize(tree: TreeSampler.new, disk: DiskSampler.new, docker: nil, interval: SAMPLE_INTERVAL)
      @tree, @disk, @docker, @interval = tree, disk, docker, interval
    end

    # {exit:, signal:, peak_rss_mb:, disk_delta_gb:, docker_mem_peak_mb:, docker_disk_delta_gb:, samples:},
    # or {exit: 127} when the command cannot start.
    def run(argv, root:, cwd:, env: {})
      before = @disk.read(root)
      docker0 = { mem: @docker&.mem_mb.to_f, disk: @docker&.disk_gb.to_f }
      pid = Process.spawn(env.merge(ACTIVE_ENV => '1'), *argv, chdir: cwd)
      stats = sample_until_exit(pid)
      after = @disk.read(root)
      finish(stats, before, after, docker0)
    rescue SystemCallError
      { exit: 127, signal: nil }
    end

    private

    def finish(stats, before, after, docker0)
      status = stats.delete(:status)
      disk = [ before[:free_gb] - after[:free_gb], after[:used_gb] - before[:used_gb], 0.0 ].max
      stats.merge(exit: status.exitstatus, signal: status.termsig && Signal.signame(status.termsig),
                  disk_delta_gb: disk.round(2),
                  docker_mem_peak_mb: [ stats[:docker_mem_peak_mb] - docker0[:mem], 0.0 ].max.round,
                  docker_disk_delta_gb: [ @docker&.disk_gb.to_f - docker0[:disk], 0.0 ].max.round(2))
    end

    def sample_until_exit(pid)
      old = FORWARDED_SIGNALS.to_h { |s| [ s, Signal.trap(s) { forward(s, pid) } ] }
      stats = { peak_rss_mb: 0.0, docker_mem_peak_mb: 0.0, samples: 0 }
      waiter = Thread.new { Process.wait2(pid).last }
      loop do
        sample(pid, stats)
        break if waiter.join(@interval)
      end
      stats[:status] = waiter.value
      stats[:peak_rss_mb] = stats[:peak_rss_mb].round
      stats
    ensure
      old&.each { |s, handler| Signal.trap(s, handler) }
    end

    def sample(pid, stats)
      stats[:peak_rss_mb] = [ stats[:peak_rss_mb], @tree.rss_mb(pid) ].max
      stats[:docker_mem_peak_mb] = [ stats[:docker_mem_peak_mb], @docker.mem_mb ].max if @docker
      stats[:samples] += 1
    end

    def forward(signal, pid)
      Process.kill(signal, pid)
    rescue SystemCallError
      nil
    end
  end

  Outcome = Struct.new(:exit_code, :signal, keyword_init: true)

  class Probe
    def initialize(root:, store:, runner: Runner.new, now: -> { Time.now.to_i })
      @root, @store, @runner, @now = root, store, runner, now
    end

    # Runs and records one op; returns an Outcome carrying the child's status.
    def probe(op, argv, cwd: @root, prereqs: [])
      result = @runner.run(argv, root: @root, cwd: cwd)
      record(op, argv, cwd, prereqs, result) if result[:exit].to_i.zero? && result[:signal].nil?
      Outcome.new(exit_code: result[:exit], signal: result[:signal])
    end

    private

    def record(op, argv, cwd, prereqs, result)
      clean, redacted = Sanitize.argv(argv, @root)
      fresh = {
        'fingerprint' => ResourceFingerprint.compute(@root), 'updated_at_epoch' => @now.call,
        'peak_rss_mb' => result[:peak_rss_mb], 'disk_delta_gb' => result[:disk_delta_gb],
        'docker_mem_peak_mb' => result[:docker_mem_peak_mb], 'docker_disk_delta_gb' => result[:docker_disk_delta_gb],
        'samples' => result[:samples], 'lower_bound' => true,
        'command' => clean, 'command_redacted' => redacted, 'cwd' => Sanitize.cwd(cwd, @root), 'prereqs' => prereqs
      }
      @store.update_op(op) { |old| Drift.merge(old, fresh) }
    end
  end

  # Forced runs of ops already registered by a real run.
  class Benchmark
    Report = Struct.new(:ran, :skipped, :unknown, keyword_init: true)

    def initialize(root:, store:, probe:)
      @root, @store, @probe = root, store, probe
    end

    def run(names)
      ops = @store.ops
      unknown = names.reject { |n| ops.key?(n) }
      report = Report.new(ran: [], skipped: [], unknown: unknown)
      names.each { |n| execute(n, ops, report, []) } if unknown.empty?
      report
    end

    private

    def execute(name, ops, report, chain)
      return if report.ran.include?(name) || report.skipped.any? { |s| s[:op] == name }

      entry = ops.fetch(name)
      reason = blocked(entry, ops, chain + [ name ])
      return report.skipped << { op: name, reason: reason } if reason

      entry['prereqs'].each { |pre| execute(pre, ops, report, chain + [ name ]) }
      failed = report.skipped.find { |s| entry['prereqs'].include?(s[:op]) }
      return report.skipped << { op: name, reason: "prereq #{failed[:op]} did not run" } if failed

      launch(name, entry, report)
    end

    def launch(name, entry, report)
      outcome = @probe.probe(name, entry['command'], cwd: File.join(@root, entry['cwd']), prereqs: entry['prereqs'])
      if outcome.exit_code.to_i.zero? && outcome.signal.nil?
        report.ran << name
      else
        report.skipped << { op: name, reason: "exited #{outcome.signal || outcome.exit_code}" }
      end
    end

    def blocked(entry, ops, chain)
      prereqs = Array(entry['prereqs'])
      return 'command had redacted values; run a real probe again' if entry['command_redacted'] || !entry['command'].is_a?(Array)
      return 'cwd outside the repo' if entry['cwd'].to_s.start_with?('/', '..')

      missing = prereqs.find { |p| !ops.key?(p) }
      return "prereq #{missing} is not registered" if missing

      "prereq cycle at #{chain.last}" if prereqs.any? { |p| chain.include?(p) }
    end
  end

  # Staleness for display: fingerprint mismatch or age over the TTL.
  def self.staleness(entry, fingerprint, now:, ttl_seconds:)
    return 'fingerprint changed' if entry['fingerprint'] != fingerprint
    return 'older than TTL' if entry['updated_at_epoch'].nil? || now - entry['updated_at_epoch'].to_i > ttl_seconds

    nil
  end

  def self.show_text(ops, fingerprint, now:, ttl_seconds:)
    return "no profile recorded yet\n" if ops.empty?

    lines = ops.sort.map do |name, e|
      stale = staleness(e, fingerprint, now: now, ttl_seconds: ttl_seconds)
      age = e['updated_at_epoch'] ? "#{((now - e['updated_at_epoch'].to_i) / 86_400.0).round(1)}d ago" : 'never'
      "#{name}: peak_rss_mb=#{e['peak_rss_mb']} disk_delta_gb=#{e['disk_delta_gb']} docker_mem_peak_mb=#{e['docker_mem_peak_mb']} " \
        "docker_disk_delta_gb=#{e['docker_disk_delta_gb']} updated #{age} #{stale ? "STALE (#{stale})" : 'fresh'}"
    end
    "#{lines.join("\n")}\nnote: peaks are sampled about once a second, so they are lower bounds\n"
  end

  def self.ttl_seconds(env)
    ResourceGate::Floors.new(platform: ResourceGate.platform, repo_file: ResourceGate.defaults_file,
                             user_file: ResourceGate::USER_FLOORS_FILE, env: env).ttl_seconds
  end

  def self.docker_sampler(op, argv)
    op.match?(ResourceGate::DOCKER_OP) || argv.first(2).join(' ').match?(ResourceGate::DOCKER_OP) ? DockerSampler.new : nil
  end

  def self.parse(argv)
    opts = { project: Dir.pwd, prereqs: [], json: false }
    parser = OptionParser.new do |o|
      o.banner = 'usage: resource_probe.rb probe <op> [--prereq OP]... -- <cmd...> | benchmark <op>... | show [--project DIR] [--json]'
      o.on('--project DIR') { |v| opts[:project] = v }
      o.on('--prereq OP') { |v| opts[:prereqs] << v }
      o.on('--json') { opts[:json] = true }
    end
    split = argv.index('--')
    head = split ? argv[0...split] : argv
    [ parser.parse(head), split ? argv[(split + 1)..] : [], opts, parser ]
  end

  # Re-raises the child's signal on this process so the caller sees the same death.
  def self.relay_signal(signal)
    Signal.trap(signal, 'DEFAULT')
    Process.kill(signal, Process.pid)
    sleep 0.1
    128 + Signal.list.fetch(signal, 0)
  end

  def self.run(argv, env: ENV, out: $stdout, err: $stderr, home: Dir.home, runner: nil, killer: method(:relay_signal))
    args, cmd, opts, parser = parse(argv)
    sub, *names = args
    ident = CfProjectIdentity.for(opts[:project])
    store = Store.new(slug: ident.slug, home: home)
    case sub
    when 'probe' then run_probe(names.first, cmd, opts, ident, store, env, err, runner, killer)
    when 'benchmark' then run_benchmark(names, ident, store, out, err, runner)
    when 'show' then run_show(ident, store, opts, env, out)
    else
      err.puts parser.banner
      2
    end
  rescue ArgumentError, OptionParser::ParseError, SystemCallError => e
    err.puts "resource_probe: #{e.message}"
    2
  end

  def self.run_probe(op, cmd, opts, ident, store, env, err, runner, killer)
    unless op.to_s.match?(/\A[\w.-]+\z/) && cmd.any?
      err.puts 'usage: resource_probe.rb probe <op> -- <cmd...>'
      return 2
    end
    # Nested under a probe: run the command as is, never wrap or record twice.
    return passthrough(cmd, killer) if env[ACTIVE_ENV] == '1'

    runner ||= Runner.new(docker: docker_sampler(op, cmd))
    cwd = File.realpath(opts[:project])
    outcome = Probe.new(root: ident.root, store: store, runner: runner).probe(op, cmd, cwd: cwd, prereqs: opts[:prereqs])
    outcome.signal ? killer.call(outcome.signal) : outcome.exit_code
  end

  def self.passthrough(cmd, killer)
    status = Process.wait2(Process.spawn(*cmd)).last
    status.termsig ? killer.call(Signal.signame(status.termsig)) : status.exitstatus
  rescue SystemCallError
    127
  end

  def self.run_benchmark(names, ident, store, out, err, runner)
    if names.empty?
      err.puts 'usage: resource_probe.rb benchmark <op> [<op>...]'
      return 2
    end
    probe = Probe.new(root: ident.root, store: store, runner: runner || Runner.new)
    report = Benchmark.new(root: ident.root, store: store, probe: probe).run(names)
    if report.unknown.any?
      err.puts "resource_probe: unknown op #{report.unknown.join(', ')} (run it once under `probe` first)"
      return 2
    end
    out.puts "ran: #{report.ran.join(', ')}" if report.ran.any?
    report.skipped.each { |s| out.puts "skipped #{s[:op]}: #{s[:reason]}" }
    report.skipped.empty? ? 0 : 1
  end

  def self.run_show(ident, store, opts, env, out)
    ops = store.ops
    if opts[:json]
      out.puts JSON.generate(ops)
    else
      out.print show_text(ops, ResourceFingerprint.compute(ident.root), now: Time.now.to_i, ttl_seconds: ttl_seconds(env))
    end
    0
  end
end

exit(ResourceProbe.run(ARGV)) if $PROGRAM_NAME == __FILE__
