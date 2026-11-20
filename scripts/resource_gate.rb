# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'timeout'
require 'yaml'
require_relative 'change_docker'
require_relative 'cf_pids'
require_relative 'cf_project_identity'
require_relative 'resource_fingerprint'

# Fail-closed gate on available RAM and free disk before cf spawns heavy work.
#
#   ruby scripts/resource_gate.rb check --json [--project DIR]
#       [--batch op:count[,op:count]]... [--worktrees N] [--reclaim-safe]
#
# Exit codes: 0 ok, 2 usage, 3 below floor after reclaim, 4 measurement error.
# A reading that is missing, times out or does not parse is exit 4 with the
# failed reader in `notes`; there is no path where the remaining readings
# decide. Readers are injected objects so tests never run a real command.
module ResourceGate
  PLATFORM_MIN = {
    'linux' => { ram_mb: 2048, disk_gb: 10 },
    'darwin' => { ram_mb: 2048, disk_gb: 15 }
  }.freeze
  LINUX_RAM_PERCENT = 0.10
  DOCKER_DF_IMAGE = 'alpine@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf'
  DOCKER_OP = /docker|compose/i
  READ_TIMEOUT = 15
  KB_PER_GB = 1024.0 * 1024.0
  GB = 1024.0**3

  class MeasurementError < StandardError
    attr_reader :reader

    def initialize(reader, detail)
      @reader = reader
      super("#{reader}: #{detail}")
    end
  end

  # Runs one command with a timeout; any failure is a MeasurementError.
  class Runner
    def initialize(timeout: READ_TIMEOUT) = @timeout = timeout

    def call(reader, *argv)
      Open3.popen2e(*argv) do |stdin, out, wait|
        stdin.close
        reader_thread = Thread.new { out.read }
        unless wait.join(@timeout)
          Process.kill('KILL', wait.pid)
          wait.join
          raise MeasurementError.new(reader, "#{argv.first} timed out")
        end
        raise MeasurementError.new(reader, "#{argv.first} exited #{wait.value.exitstatus}") unless wait.value.success?

        reader_thread.value
      end
    rescue SystemCallError => e
      raise MeasurementError.new(reader, "#{argv.first} unavailable (#{e.class})")
    end
  end

  def self.platform(host_os = RbConfig::CONFIG['host_os'])
    host_os.to_s.include?('darwin') ? 'darwin' : 'linux'
  end

  # {available_mb:, total_mb:, pressure_normal:} (pressure_normal is nil on Linux).
  class MemReader
    def initialize(platform: ResourceGate.platform, runner: Runner.new, meminfo: -> { File.read('/proc/meminfo') })
      @platform, @runner, @meminfo = platform, runner, meminfo
    end

    def read = @platform == 'darwin' ? read_darwin : read_linux

    private

    def read_linux
      text = @meminfo.call
      avail = text[/^MemAvailable:\s+(\d+)\s*kB/, 1]
      total = text[/^MemTotal:\s+(\d+)\s*kB/, 1]
      raise MeasurementError.new('memory', 'MemAvailable or MemTotal missing') unless avail && total

      { available_mb: avail.to_i / 1024, total_mb: total.to_i / 1024, pressure_normal: nil }
    rescue SystemCallError => e
      raise MeasurementError.new('memory', "meminfo unreadable (#{e.class})")
    end

    def read_darwin
      free_pct = @runner.call('memory_pressure', 'memory_pressure')[/free percentage:\s*(\d+)%/, 1]
      total = @runner.call('memory', 'sysctl', '-n', 'hw.memsize').strip
      level = @runner.call('memory', 'sysctl', '-n', 'kern.memorystatus_vm_pressure_level').strip
      raise MeasurementError.new('memory_pressure', 'free percentage not found') unless free_pct
      raise MeasurementError.new('memory', 'hw.memsize did not parse') unless total.match?(/\A\d+\z/)
      raise MeasurementError.new('memory', 'pressure level did not parse') unless level.match?(/\A\d+\z/)

      total_mb = total.to_i / (1024 * 1024)
      { available_mb: (total_mb * free_pct.to_i / 100.0).floor, total_mb: total_mb, pressure_normal: level.to_i == 1 }
    end
  end

  # Free GB on the volume holding a path.
  class DiskReader
    def initialize(runner: Runner.new) = @runner = runner

    def free_gb(path)
      line = @runner.call('disk', 'df', '-Pk', path).lines.last.to_s.split
      raise MeasurementError.new('disk', "df output for #{path} did not parse") unless line.length >= 4 && line[3].match?(/\A\d+\z/)

      (line[3].to_i / KB_PER_GB).round(2)
    end
  end

  # Docker readings, taken only when a batch needs Docker. Returns
  # {vm_total_mb:, vm_used_mb:, vm_free_gb:, reclaimable_gb:}.
  class DockerReader
    SCALE = { 'k' => 1 / 1024.0, 'm' => 1.0, 'g' => 1024.0, 't' => 1024.0 * 1024, 'b' => 1 / (1024.0 * 1024) }.freeze

    def initialize(platform: ResourceGate.platform, runner: Runner.new, disk: DiskReader.new(runner: runner))
      @platform, @runner, @disk = platform, runner, disk
    end

    def read
      info = parse_json('docker_info') { @runner.call('docker_info', 'docker', 'info', '--format', '{{json .}}') }
      total = Integer(info['MemTotal'], exception: false)
      raise MeasurementError.new('docker_info', 'MemTotal missing') unless total&.positive?

      { vm_total_mb: total / (1024 * 1024), vm_used_mb: used_mb, vm_free_gb: free_gb(info), reclaimable_gb: reclaimable_gb }
    end

    private

    def parse_json(reader)
      JSON.parse(yield)
    rescue JSON::ParserError
      raise MeasurementError.new(reader, 'output did not parse')
    end

    def rows(reader, *cmd)
      @runner.call(reader, *cmd).lines.map(&:strip).reject(&:empty?).map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        raise MeasurementError.new(reader, 'output did not parse')
      end
    end

    def used_mb
      rows('docker_stats', 'docker', 'stats', '--no-stream', '--format', '{{json .}}').sum { |r| size_mb(r['MemUsage'].to_s.split('/').first) }
    end

    def free_gb(info)
      return @disk.free_gb(info['DockerRootDir'].to_s) if @platform == 'linux'

      # /var/lib/docker is not mounted in a fresh container; its root sits on the VM disk.
      out = @runner.call('docker_vm_df', 'docker', 'run', '--rm', DOCKER_DF_IMAGE, 'df', '-Pk', '/')
      avail = out.lines.last.to_s.split[3]
      raise MeasurementError.new('docker_vm_df', 'df output did not parse') unless avail&.match?(/\A\d+\z/)

      (avail.to_i / KB_PER_GB).round(2)
    end

    def reclaimable_gb
      rows('docker_df', 'docker', 'system', 'df', '--format', '{{json .}}').sum { |r| size_mb(r['Reclaimable'].to_s.split.first) } / 1024.0
    end

    def size_mb(text)
      m = text.to_s.strip.match(/\A([\d.]+)\s*([kKmMgGtT]?)i?[bB]\z/)
      raise MeasurementError.new('docker_size', "size #{text.inspect} did not parse") unless m

      m[1].to_f * SCALE.fetch(m[2].empty? ? 'b' : m[2].downcase)
    end
  end

  # Tier-1 reclaim (safe, automatic) and tier-2 candidates (listed, never deleted).
  class Reclaimer
    DUMP_MIN_BYTES = 100 * 1024 * 1024

    def initialize(project:, runner: Runner.new, pids: nil)
      @project, @runner, @pids = project, runner, pids
    end

    # Returns the PIDs stopped. A prune that fails (Docker absent or stopped)
    # is skipped and never aborts the gate; the re-measure decides. The stale
    # network sweep is a safe reclaim too: it removes only idle, hour-old,
    # cf-labeled networks (ChangeDocker.sweep_stale_networks).
    def reclaim_safe
      [ %w[docker image prune -f], %w[docker builder prune -f] ].each { |cmd| attempt(cmd) }
      sweep_networks
      @pids ? @pids.stop_matching : []
    end

    def candidates = worktrees + dumps

    private

    def sweep_networks
      ChangeDocker.sweep_stale_networks(runner: ->(*argv) { @runner.call('reclaim', *argv) })
    rescue MeasurementError
      nil
    end

    def attempt(cmd)
      @runner.call('reclaim', *cmd)
    rescue MeasurementError
      nil
    end

    def worktrees
      listing = @runner.call('worktrees', 'git', '-C', @project, 'worktree', 'list', '--porcelain')
      paths = listing.scan(/^worktree (.+)$/).flatten.reject { |p| p == @project }
      paths.filter_map { |p| size_entry(p) }
    rescue MeasurementError
      []
    end

    def dumps
      Dir.glob(File.join(@project, '**', '*.{dump,sql,sql.gz}'))
         .reject { |f| f.include?('/node_modules/') || f.include?('/.git/') }
         .select { |f| File.file?(f) && File.size(f) >= DUMP_MIN_BYTES }
         .map { |f| { kind: 'db_dump', path: f, size_gb: (File.size(f) / GB).round(2) } }
    end

    def size_entry(path)
      kb = @runner.call('du', 'du', '-sk', path).split.first.to_i
      { kind: 'worktree', path: path, size_gb: (kb / KB_PER_GB).round(2) }
    rescue MeasurementError
      nil
    end
  end

  # Resolves floors: platform minimum, raised by repo file, user file, env.
  class Floors
    ENV_NAMES = { 'ram_mb' => 'CF_FLOOR_RAM_MB', 'disk_gb' => 'CF_FLOOR_DISK_GB' }.freeze
    HEADROOM = { fresh: 1.25, stale: 1.5, default: 2.0 }.freeze

    attr_reader :warnings, :config

    def initialize(platform:, repo_file:, user_file:, env:)
      @warnings = []
      @config = load_yaml(repo_file) || {}
      @warnings << "shipped floors defaults missing at #{repo_file}; using built-in fallbacks" unless File.file?(repo_file)
      min = PLATFORM_MIN.fetch(platform)
      @floor = { 'ram_mb' => min[:ram_mb], 'disk_gb' => min[:disk_gb] }
      raise_with(@config['floors'], repo_file, warn: false) # shipped defaults, below the macOS minimum by design
      raise_with(load_yaml(user_file)&.dig('floors'), user_file)
      raise_with(ENV_NAMES.to_h { |key, name| [ key, env[name] ] }, nil)
    end

    def ram_mb = @floor['ram_mb']
    def disk_gb = @floor['disk_gb']
    def headroom(kind) = Float(@config.dig('headroom', kind.to_s) || HEADROOM.fetch(kind))
    def ttl_seconds = Float(@config['ttl_days'] || 30) * 86_400
    def defaults = @config['defaults'] || {}

    private

    def load_yaml(path)
      return nil unless path && File.file?(path)

      data = YAML.safe_load_file(path)
      data.is_a?(Hash) ? data : nil
    rescue Psych::Exception, SystemCallError
      @warnings << "ignored unreadable floors file #{path}"
      nil
    end

    # A value below the current floor, or one that does not parse, is ignored
    # with a warning naming its source (file path, or the env var).
    def raise_with(values, source, warn: true)
      return unless values.is_a?(Hash)

      @floor.each_key do |key|
        raw = values[key]
        next if raw.nil?

        label = source || ENV_NAMES.fetch(key)
        value = Float(raw, exception: false)
        if value.nil? || value < @floor[key]
          @warnings << "ignored #{key} #{raw.inspect} from #{label}: floors can only be raised (effective #{@floor[key]})" if warn
        else
          @floor[key] = value.ceil
        end
      end
    end
  end

  Result = Struct.new(:json, :exit_code, keyword_init: true)

  class Gate
    def initialize(project:, floors:, mem:, disk:, docker: nil, reclaimer: nil, profile: {}, now: Time.now, platform: ResourceGate.platform)
      @project, @floors, @mem, @disk, @docker_reader, @reclaimer = project, floors, mem, disk, docker, reclaimer
      @profile, @now, @platform = profile, now, platform
    end

    # batches: [[{op:, count:}, ...], ...]. Each inner list runs concurrently;
    # separate lists run one after another.
    def check(batches: [], worktrees: 1, reclaim_safe: false)
      ops = batches.flatten.map { |b| b[:op] }.uniq
      resolved = resolve(ops)
      need_docker = ops.any? { |op| docker_op?(op) } || resolved.values.any? { |r| r[:docker_mem_mb].positive? || r[:docker_disk_gb].positive? }
      reclaimed = { disk_gb: 0.0, pids: [] }
      reading = measure(need_docker)
      below = shortfalls(reading, batches, resolved, worktrees)
      if below.any? && reclaim_safe && @reclaimer
        before = reading[:disk_gb]
        reclaimed[:pids] = @reclaimer.reclaim_safe
        reading = measure(need_docker)
        reclaimed[:disk_gb] = [ (reading[:disk_gb] - before).round(2), 0.0 ].max
        below = shortfalls(reading, batches, resolved, worktrees)
      end
      build(reading, below, batches, resolved, worktrees, reclaimed)
    rescue MeasurementError => e
      error_result(e)
    end

    private

    def measure(need_docker)
      reading = { mem: @mem.read, disk_gb: @disk.free_gb(@project) }
      if need_docker
        raise MeasurementError.new('docker', 'no reader available') unless @docker_reader

        reading[:docker] = @docker_reader.read
      end
      reading
    end

    def ram_floor(mem)
      pct = @platform == 'linux' ? (mem[:total_mb] * LINUX_RAM_PERCENT).ceil : 0
      [ @floors.ram_mb, pct ].max
    end

    def docker_op?(op)
      entry = @profile[op]
      op.match?(DOCKER_OP) || (entry && (entry['docker_mem_peak_mb'].to_f.positive? || entry['docker_disk_delta_gb'].to_f.positive?))
    end

    # {op => {ram_mb:, disk_gb:, docker_mem_mb:, docker_disk_gb:, source:}}, RAM already headroomed.
    def resolve(ops)
      ops.to_h { |op| [ op, @profile[op] ? from_profile(@profile[op]) : default_need(op) ] }
    end

    def from_profile(entry)
      h = @floors.headroom(stale?(entry) ? :stale : :fresh)
      { ram_mb: entry['peak_rss_mb'].to_f * h, disk_gb: entry['disk_delta_gb'].to_f, docker_mem_mb: entry['docker_mem_peak_mb'].to_f * h,
        docker_disk_gb: entry['docker_disk_delta_gb'].to_f, source: 'profile' }
    end

    def stale?(entry)
      return true if entry['stale']

      updated = entry['updated_at_epoch']
      updated.nil? || (@now.to_i - updated.to_i) > @floors.ttl_seconds
    end

    # Cautious default by repo kind: one language kind, plus Docker-heavy on top.
    def default_need(op)
      kinds = repo_kinds
      base = @floors.defaults[kinds.first.to_s] || { 'ram_mb' => 2048, 'disk_gb' => 4 }
      docker = @floors.defaults['docker'] || {}
      ram, disk = base['ram_mb'].to_f, base['disk_gb'].to_f
      with_docker = kinds.include?(:docker)
      ram, disk = ram + docker['ram_mb'].to_f, disk + docker['disk_gb'].to_f if with_docker
      h = @floors.headroom(:default)
      docker_mem = with_docker || op.match?(DOCKER_OP) ? docker['ram_mb'].to_f * h : 0.0
      { ram_mb: ram * h, disk_gb: disk, docker_mem_mb: docker_mem, docker_disk_gb: 0.0, source: 'default' }
    end

    def repo_kinds
      lang = if File.exist?(File.join(@project, 'package.json')) then :node
      elsif File.exist?(File.join(@project, 'Gemfile')) then :ruby
      else :other
      end
      Dir.glob(File.join(@project, '{Dockerfile*,docker-compose*.y*ml,compose*.y*ml}')).any? ? [ lang, :docker ] : [ lang ]
    end

    def ram_need(batches, resolved)
      batches.map { |b| b.sum { |e| resolved.fetch(e[:op])[:ram_mb] * e[:count] } }.max || 0.0
    end

    def docker_mem_need(batches, resolved)
      batches.map { |b| b.sum { |e| resolved.fetch(e[:op])[:docker_mem_mb] * e[:count] } }.max || 0.0
    end

    def need_ram(mem, batches, resolved) = [ ram_floor(mem), ram_need(batches, resolved) ].max

    def need_disk(resolved, worktrees)
      @floors.disk_gb + resolved.values.sum { |r| r[:disk_gb] } * [ worktrees, 1 ].max
    end

    def shortfalls(reading, batches, resolved, worktrees)
      mem = reading[:mem]
      floor_ram = ram_floor(mem)
      ram = need_ram(mem, batches, resolved)
      disk = need_disk(resolved, worktrees)
      list = []
      list << 'memory pressure is not normal' if mem[:pressure_normal] == false
      list << "available RAM #{mem[:available_mb]} MB below absolute floor #{floor_ram} MB" if mem[:available_mb] < floor_ram
      list << "free disk #{reading[:disk_gb]} GB below absolute floor #{@floors.disk_gb} GB" if reading[:disk_gb] < @floors.disk_gb
      list << "available RAM #{mem[:available_mb]} MB below need #{ram.ceil} MB" if mem[:available_mb] < ram
      list << "free disk #{reading[:disk_gb]} GB below need #{disk.ceil} GB" if reading[:disk_gb] < disk
      list.concat(docker_shortfalls(reading[:docker], batches, resolved)) if reading[:docker]
      list
    end

    def docker_shortfalls(docker, batches, resolved)
      list = []
      peak = docker_mem_need(batches, resolved)
      if docker[:vm_used_mb] + peak > docker[:vm_total_mb]
        list << "Docker VM memory #{docker[:vm_used_mb].ceil} MB used plus #{peak.ceil} MB needed exceeds VM cap #{docker[:vm_total_mb]} MB"
      end
      need = @floors.disk_gb + resolved.values.sum { |r| r[:docker_disk_gb] }
      list << "Docker free disk #{docker[:vm_free_gb]} GB below need #{need.ceil} GB" if docker[:vm_free_gb] < need
      list
    end

    def build(reading, below, batches, resolved, worktrees, reclaimed)
      mem = reading[:mem]
      provisional = resolved.empty? || resolved.values.any? { |r| r[:source] == 'default' }
      ok = below.empty?
      payload = {
        ok: ok, error: nil, notes: @floors.warnings + below,
        ram_available_mb: mem[:available_mb], disk_free_gb: reading[:disk_gb],
        need: { ram_mb: need_ram(mem, batches, resolved).ceil, disk_gb: need_disk(resolved, worktrees).ceil, source: provisional ? 'default' : 'profile' },
        reclaimed: reclaimed, candidates: ok || !@reclaimer ? [] : @reclaimer.candidates, provisional: provisional
      }
      Result.new(json: payload, exit_code: ok ? 0 : 3)
    end

    def error_result(error)
      payload = { ok: false, error: 'measurement', notes: @floors.warnings + [ error.message ], ram_available_mb: nil, disk_free_gb: nil,
                  need: nil, reclaimed: { disk_gb: 0.0, pids: [] }, candidates: [], provisional: true }
      Result.new(json: payload, exit_code: 4)
    end
  end

  USER_FLOORS_FILE = File.join(Dir.home, '.claude', 'cf', 'config', 'resource_floors.yml')
  # An installed copy carries the shipped defaults as resource_floors.defaults.yml,
  # because resource_floors.yml beside it is the user's own override file.
  def self.defaults_file
    config = File.expand_path('../config', __dir__)
    installed = File.join(config, 'resource_floors.defaults.yml')
    File.exist?(installed) ? installed : File.join(config, 'resource_floors.yml')
  end

  # Parses "op:count,op:count" into [{op:, count:}]; raises ArgumentError.
  def self.parse_batch(text)
    list = text.split(',').map do |item|
      op, count = item.split(':', 2)
      n = Integer(count || '1', exception: false)
      raise ArgumentError, "bad batch item #{item.inspect}" unless op.to_s.match?(/\A[\w.-]+\z/) && n&.positive?

      { op: op, count: n }
    end
    raise ArgumentError, 'empty batch' if list.empty?

    list
  end

  # The stored profile's ops for a project, or {} when none is recorded yet. An
  # op whose fingerprint no longer matches the repo is marked stale.
  def self.load_profile(project, home: Dir.home)
    ident = CfProjectIdentity.for(project)
    data = JSON.parse(File.read(File.join(home, '.claude', 'cf', 'benchmarks', ident.slug, 'profile.json')))
    return {} unless data['ops'].is_a?(Hash)

    current = ResourceFingerprint.compute(CfProjectIdentity.checkout_root(File.realpath(project)) || ident.root)
    data['ops'].transform_values { |e| e.is_a?(Hash) && e['fingerprint'] != current ? e.merge('stale' => true) : e }
  rescue StandardError
    {}
  end

  def self.build_gate(project, opts, env)
    platform = ResourceGate.platform
    runner = Runner.new
    floors = Floors.new(platform: platform, repo_file: defaults_file, user_file: USER_FLOORS_FILE, env: env)
    pids = opts[:session] ? CfPids.new(session: opts[:session]) : nil
    Gate.new(project: project, floors: floors, mem: MemReader.new(platform: platform, runner: runner), disk: DiskReader.new(runner: runner),
             docker: DockerReader.new(platform: platform, runner: runner),
             reclaimer: Reclaimer.new(project: project, runner: runner, pids: pids),
             profile: load_profile(project), platform: platform)
  end

  def self.summary(result)
    j = result.json
    status = j[:ok] ? 'ok' : "blocked (#{j[:error] || 'below floor'})"
    ([ "resource gate: #{status}", "ram_available_mb=#{j[:ram_available_mb]} disk_free_gb=#{j[:disk_free_gb]}" ] + j[:notes]).join("\n")
  end

  def self.parser(opts)
    OptionParser.new do |o|
      o.banner = 'usage: resource_gate.rb check [--json] [--project DIR] [--batch op:count,...]... [--worktrees N] [--reclaim-safe]'
      o.on('--json') { opts[:json] = true }
      o.on('--project DIR') { |v| opts[:project] = v }
      o.on('--batch SPEC') { |v| opts[:batches] << parse_batch(v) }
      o.on('--worktrees N', Integer) { |v| opts[:worktrees] = v }
      o.on('--session ID') { |v| opts[:session] = v }
      o.on('--reclaim-safe') { opts[:reclaim] = true }
    end
  end

  def self.run(argv, env: ENV, out: $stdout, err: $stderr)
    opts = { batches: [], worktrees: 1, json: false, reclaim: false, project: Dir.pwd, session: env['CF_SESSION_ID'] }
    parser = parser(opts)
    unless parser.parse(argv).first == 'check'
      err.puts parser.banner
      return 2
    end
    gate = build_gate(File.realpath(opts[:project]), opts, env)
    result = gate.check(batches: opts[:batches], worktrees: opts[:worktrees], reclaim_safe: opts[:reclaim])
    out.puts(opts[:json] ? JSON.generate(result.json) : summary(result))
    result.exit_code
  rescue ArgumentError, OptionParser::ParseError, SystemCallError => e
    err.puts "resource_gate: #{e.message}"
    2
  end
end

exit(ResourceGate.run(ARGV)) if $PROGRAM_NAME == __FILE__
