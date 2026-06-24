#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'rbconfig'

# Installs the pst merge-mode shim: hook scripts, the skill symlink, and the
# settings.json wiring. Internals are namespaced so the file stays one unit.
module Install
  # Resolves every source and destination path the installer touches.
  class Paths
    def initialize(repo:, home:)
      @repo = repo
      @home = home
    end

    def scripts      = File.join(@repo, 'scripts')
    def skill_source = File.join(@repo, 'skills', 'pst')
    def bin          = File.join(@home, '.claude', 'pst', 'bin')
    def skill_link   = File.join(@home, '.claude', 'skills', 'pst')
    def settings     = File.join(@home, '.claude', 'settings.json')

    def scripts_glob      = Dir.glob(File.join(scripts, '*.rb'))
    def script_dest(name) = File.join(bin, name)
  end

  # Resolves the absolute path of the running Ruby interpreter for hook shebangs.
  module RubyInterpreter
    def self.path
      resolved = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
      raise 'could not resolve a ruby interpreter' unless File.executable?(resolved)

      resolved
    end
  end

  # Wires managed hooks into ~/.claude/settings.json idempotently, with a backup.
  class SettingsFile
    def initialize(path, managed_dir:)
      @path = path
      @managed_dir = managed_dir
    end

    def wire(events)
      data = load
      hooks = (data['hooks'] ||= {})
      clear_managed_hooks(hooks)
      add_event_hooks(hooks, events)
      persist(data)
    end

    def backup_path = "#{@path}.bak"

    private

    def load
      File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    end

    def clear_managed_hooks(hooks)
      hooks.each_value { |section| drop_managed_hooks(section) if section.is_a?(Array) }
      hooks.reject! { |_, section| section.is_a?(Array) && section.empty? }
    end

    def add_event_hooks(hooks, events)
      events.each do |event, command|
        section = (hooks[event] ||= [])
        section << { 'hooks' => [ { 'type' => 'command', 'command' => command } ] }
      end
    end

    def drop_managed_hooks(section)
      section.each { |group| remove_managed_from_group(group) }
      section.reject! { |group| group.is_a?(Hash) && (group['hooks'] || []).empty? }
    end

    def remove_managed_from_group(group)
      return unless group.is_a?(Hash) && group['hooks'].is_a?(Array)

      group['hooks'].reject! { |hook| hook['command'].to_s.include?(@managed_dir) }
    end

    def persist(data)
      FileUtils.cp(@path, backup_path) if File.exist?(@path)
      tmp = "#{@path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, @path)
    end
  end

  # Top-level orchestration: copies hooks, links the skill, and wires settings.
  class Installer
    HOOKS = {
      'SessionStart' => 'session_start.rb',
      'PreToolUse' => 'merge_mode_guard.rb',
      'PostToolUse' => 'merge_mode_record.rb',
      'UserPromptSubmit' => 'merge_mode_restate.rb'
    }.freeze

    def initialize(paths:, ruby:)
      @paths = paths
      @ruby = ruby
    end

    def install
      place_hooks
      link_skill
      report(wire_settings)
    end

    private

    def place_hooks
      FileUtils.rm_rf(@paths.bin)
      FileUtils.mkdir_p(@paths.bin)
      @paths.scripts_glob.each do |source|
        dest = @paths.script_dest(File.basename(source))
        FileUtils.cp(source, dest)
        FileUtils.chmod(0o755, dest)
      end
    end

    def link_skill
      FileUtils.mkdir_p(File.dirname(@paths.skill_link))
      FileUtils.rm_f(@paths.skill_link) if File.symlink?(@paths.skill_link)
      FileUtils.ln_sf(@paths.skill_source, @paths.skill_link)
    end

    def wire_settings
      settings = SettingsFile.new(@paths.settings, managed_dir: @paths.bin)
      settings.wire(commands)
      settings
    end

    def commands
      HOOKS.to_h { |event, name| [ event, "#{@ruby} #{@paths.script_dest(name)}" ] }
    end

    def report(settings)
      puts 'merge-mode shim installed:'
      puts "  hooks    -> #{@paths.bin} (#{HOOKS.keys.join(', ')})"
      puts "  skill    -> #{@paths.skill_link}"
      puts "  settings -> #{@paths.settings} (backup at #{settings.backup_path})"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  paths = Install::Paths.new(repo: __dir__, home: Dir.home)
  Install::Installer.new(paths: paths, ruby: Install::RubyInterpreter.path).install
end
