#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'rbconfig'
require_relative 'cf_doctor'
require_relative 'cf_install_manifest'
require_relative 'native_hook_install'
require_relative 'cf_runtime'

# A small command surface for diagnostics and explicit state operations.
class CfCli
  def self.unwire_legacy_hooks(home, plan)
    path = File.join(home, '.claude/settings.json')
    return unless File.file?(path)

    bin = File.realpath(File.join(home, '.claude/cf/bin'))
    owned = plan.map { |row| row['path'] }.select { |file| File.dirname(file) == bin }
    data = JSON.parse(File.read(path))
    data.fetch('hooks', {}).each_value do |groups|
      next unless groups.is_a?(Array)

      groups.each do |group|
        next unless group.is_a?(Hash) && group['hooks'].is_a?(Array)

        group['hooks'].reject! do |hook|
          next false unless hook.is_a?(Hash)

          words = Shellwords.split(hook['command'].to_s)
          script = words[1]
          script && File.exist?(script) && owned.include?(File.realpath(script))
        rescue ArgumentError
          false
        end
      end
      groups.reject! { |group| group.is_a?(Hash) && group['hooks'] == [] }
    end
    File.write("#{path}.tmp", JSON.pretty_generate(data) + "\n")
    File.rename("#{path}.tmp", path)
  rescue Errno::ENOENT
    nil
  end

  def self.run(argv, io: $stdout, home: Dir.home)
    command = argv.shift
    options = { host: 'codex', surface: 'cli', project: Dir.pwd }
    parser = OptionParser.new do |flags|
      flags.on('--host HOST', SkillCompiler::HOSTS) { |value| options[:host] = value }
      flags.on('--surface SURFACE') { |value| options[:surface] = value }
      flags.on('--version VERSION') { |value| options[:version] = value }
      flags.on('--project PATH') { |value| options[:project] = value }
      flags.on('--session ID') { |value| options[:session] = value }
      flags.on('--mode MODE') { |value| options[:mode] = value }
      flags.on('--json') { options[:json] = true }
      flags.on('--apply') { options[:apply] = true }
    end
    parser.parse!(argv)
    case command
    when 'doctor'
      report = CfDoctor.new(home: home).report(host: options[:host], surface: options[:surface], version: options[:version])
      if options[:json]
        io.puts JSON.pretty_generate(report)
      else
        io.puts "#{report['host']} (#{report['binary_version'] || 'binary not detected'}), #{report['surface']}"
        io.puts "Skills: #{report.dig('skills', 'files_present')} files present; host discovery not probed. Invoke #{report['invocation']}."
        io.puts "Adapter configured: #{report.dig('adapter', 'configured')}; active/trusted: not probed."
        io.puts "Version evidence: #{report.dig('capabilities', 'version_status')}; live scope: #{report.dig('capabilities', 'live_scope') || 'not run'}."
        io.puts "State: #{report['state_root']}"
        report['next_steps'].each { |step| io.puts step }
      end
    when 'mode'
      raise ArgumentError, '--session is required; never infer a shared session from cwd' unless options[:session]

      availability = %w[active away].include?(options[:mode])
      event = options[:mode] ? (availability ? 'availability.set' : 'mode.set') : 'context'
      result = CfRuntime.new({ 'version' => 1, 'host' => options[:host], 'project' => options[:project],
        'session_id' => options[:session], 'event' => event, 'mode' => options[:mode], 'availability' => availability ? options[:mode] : nil }, root: CfState.root(home: home), home: home).call
      io.puts JSON.pretty_generate(result)
    when 'uninstall'
      manifest = CfInstallManifest.new(path: File.join(home, '.local/share/change-fabric/installation.json'), home: home)
      plan = manifest.plan
      if options[:apply]
        bin = File.join(home, '.local/share/change-fabric/bin')
        { 'claude' => '.claude/settings.json', 'codex' => '.codex/hooks.json', 'copilot' => '.copilot/hooks/change-fabric.json' }.each do |host, relative|
          NativeHookInstall.new(path: File.join(home, relative), host: host, ruby: RbConfig.ruby, bin: bin).unwire
        end
        unwire_legacy_hooks(home, plan)
        manifest.remove
      end
      io.puts JSON.pretty_generate('applied' => !!options[:apply], 'files' => plan, 'state' => 'preserved',
        'note' => 'Modified and user-owned files are preserved. Use --apply to remove unchanged managed outputs and native hooks.')
    else
      raise ArgumentError, 'Usage: cf doctor [--host HOST] [--json] | mode --session ID [--mode MODE] | uninstall [--apply]'
    end
    0
  rescue OptionParser::ParseError, ArgumentError, JSON::ParserError => e
    io.puts "cf: #{e.message}"
    1
  end
end

exit CfCli.run(ARGV) if __FILE__ == $PROGRAM_NAME
