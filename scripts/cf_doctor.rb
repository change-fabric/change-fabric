# frozen_string_literal: true

require 'json'
require 'yaml'
require 'open3'
require 'timeout'
require 'shellwords'
require_relative 'host_capabilities'
require_relative 'cf_state'
require_relative 'skill_compiler'

# Read-only installation diagnostics. File presence is never called discovery,
# and configured hooks are never called trusted or active without host evidence.
class CfDoctor
  def initialize(home: Dir.home, registry: HostCapabilities.new)
    @home, @registry = home, registry
  end

  def report(host:, surface: 'cli', version: nil, probe: true)
    raise ArgumentError, 'unknown host' unless SkillCompiler::HOSTS.include?(host)

    binary_version = version || (probe ? probe_version(host) : nil)
    profile = @registry.resolve(host: host, surface: surface, version: binary_version)
    root = skill_root(host)
    files = Dir.glob(File.join(root, 'cf*', 'SKILL.md'))
    issues = []
    files.each do |file|
      meta = YAML.safe_load(File.read(file).split(/^---\s*$\n?/)[1].to_s)
      issues << "invalid skill metadata: #{file}" unless meta.is_a?(Hash) && meta['name'] && meta['description']
    rescue Psych::Exception
      issues << "invalid skill YAML: #{file}"
    end
    runtime = File.join(@home, '.local/share/change-fabric/bin/cf_host_hook.rb')
    configured = adapter_configured?(host, runtime)
    advice = []
    advice << 'Host binary was not detected; installed files do not prove it is available.' unless binary_version
    advice << 'Run ruby install.rb from the toolkit checkout.' if files.empty? || !File.file?(runtime) || !configured
    advice << 'Use $cf-roast or /skills; /cf:roast is not a registered Codex command.' if host == 'codex'
    advice << 'Review /hooks and host feature settings. Configured does not mean trusted or active.' if host == 'codex' && configured
    advice << 'This version/surface has no verified adapter claim; run its contract and live smoke checks.' unless profile['version_status'] == 'tested'
    { 'schema_version' => 1, 'host' => host, 'surface' => surface, 'binary_version' => binary_version,
      'skills' => { 'root' => root, 'files_present' => files.length, 'host_discovery' => 'not-probed', 'issues' => issues },
      'invocation' => SkillCompiler.new(host: host).invocation('roast'),
      'adapter' => { 'configured' => configured, 'active' => 'not-probed', 'runtime_present' => File.file?(runtime) },
      'state_root' => CfState.root(home: @home), 'ruby' => RUBY_VERSION,
      'dependencies' => { 'ruby_supported' => Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2'),
                          'git_present' => executable?('git'), 'node_present' => executable?('node') },
      'capabilities' => profile, 'next_steps' => advice }
  end

  private

  def executable?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
  end

  def skill_root(host)
    relative = { 'claude' => '.claude/skills', 'codex' => '.agents/skills',
                 'copilot' => '.copilot/skills', 'opencode' => '.config/opencode/skills', 'pi' => '.pi/agent/skills' }
    File.join(@home, relative.fetch(host))
  end

  def adapter_configured?(host, runtime)
    if host == 'pi'
      return File.exist?(File.join(@home, '.pi/agent/extensions/cf-hooks'))
    elsif host == 'opencode'
      return File.file?(File.join(@home, '.config/opencode/plugins/cf-hooks.ts'))
    end
    relative = { 'claude' => '.claude/settings.json', 'codex' => '.codex/hooks.json', 'copilot' => '.copilot/hooks/change-fabric.json' }
    path = File.join(@home, relative.fetch(host))
    return false unless File.file?(path)

    data = JSON.parse(File.read(path))
    commands = if host == 'copilot'
      data.fetch('hooks', {}).values.flatten.filter_map { |entry| entry['bash'] if entry.is_a?(Hash) }
    else
      data.fetch('hooks', {}).values.flatten.flat_map do |group|
        group.is_a?(Hash) ? Array(group['hooks']).filter_map { |hook| hook['command'] if hook.is_a?(Hash) } : []
      end
    end
    commands.any? { |command| Shellwords.split(command)[1..2] == [ runtime, host ] }
  rescue JSON::ParserError, ArgumentError
    false
  end

  def probe_version(host)
    executable = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).find { |dir| File.executable?(File.join(dir, host)) }
    return unless executable

    Open3.popen2e(File.join(executable, host), '--version', pgroup: true) do |input, out, wait|
      input.close
      begin
        Timeout.timeout(3) do
          text = out.read(4096).to_s
          wait.value
          text.lines.first&.strip
        end
      rescue Timeout::Error
        Process.kill('KILL', -wait.pid)
        nil
      end
    end
  end
end
