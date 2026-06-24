#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'rbconfig'
require 'yaml'
require_relative 'scripts/skill_registry'

# Installs the pst merge-mode shim: hook scripts, the skill symlink, and the
# settings.json wiring. Internals are namespaced so the file stays one unit.
module Install
  # Resolves a skill's installed name from its SKILL.md frontmatter `name`, the
  # single source of truth for the `pst:` namespace. Keeping it here means the
  # on-disk directory stays plain and portable (no colons committed to git);
  # the namespace is applied once, at symlink time. Falls back to the directory
  # basename so a skill missing or mangling its frontmatter still links.
  module SkillName
    def self.of(source)
      front, = SkillRegistry::Frontmatter.split(File.read(File.join(source, 'SKILL.md')))
      meta = front && YAML.safe_load(front)
      name = meta['name'] if meta.is_a?(Hash)
      name.to_s.empty? ? File.basename(source) : name.to_s
    rescue StandardError
      File.basename(source)
    end
  end
  # Resolves every source and destination path the installer touches.
  class Paths
    def initialize(repo:, home:)
      @repo = repo
      @home = home
    end

    def scripts      = File.join(@repo, 'scripts')
    def skills_dir   = File.join(@repo, 'skills')
    def bin          = File.join(@home, '.claude', 'pst', 'bin')
    def skills_root  = File.join(@home, '.claude', 'skills')
    def settings     = File.join(@home, '.claude', 'settings.json')

    def scripts_glob       = Dir.glob(File.join(scripts, '*.rb'))
    def skill_sources      = Dir.glob(File.join(skills_dir, '*')).select { |p| File.directory?(p) }
    def script_dest(name)  = File.join(bin, name)
    def skill_link(name)   = File.join(skills_root, name)
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
      events.each do |event, commands|
        section = (hooks[event] ||= [])
        Array(commands).each do |command|
          section << { 'hooks' => [ { 'type' => 'command', 'command' => command } ] }
        end
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
      'SessionStart' => %w[session_start.rb skill_detect.rb],
      'PreToolUse' => %w[merge_mode_guard.rb slop_remind.rb],
      'PostToolUse' => %w[merge_mode_record.rb skill_inject.rb],
      'UserPromptSubmit' => %w[merge_mode_restate.rb],
      'Stop' => %w[skill_review.rb]
    }.freeze

    def initialize(paths:, ruby:)
      @paths = paths
      @ruby = ruby
    end

    def install
      place_hooks
      link_skills
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

    def link_skills
      @paths.skill_sources.each do |source|
        link = @paths.skill_link(SkillName.of(source))
        FileUtils.mkdir_p(File.dirname(link))
        FileUtils.rm_f(link) if File.symlink?(link)
        FileUtils.ln_sf(source, link)
      end
    end

    def wire_settings
      settings = SettingsFile.new(@paths.settings, managed_dir: @paths.bin)
      settings.wire(commands)
      settings
    end

    def commands
      HOOKS.to_h do |event, names|
        [ event, names.map { |name| "#{@ruby} #{@paths.script_dest(name)}" } ]
      end
    end

    def report(settings)
      skills = @paths.skill_sources.map { |s| SkillName.of(s) }.join(', ')
      puts 'pst shim installed:'
      puts "  hooks    -> #{@paths.bin} (#{HOOKS.keys.join(', ')})"
      puts "  skills   -> #{@paths.skills_root} (#{skills})"
      puts "  settings -> #{@paths.settings} (backup at #{settings.backup_path})"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  paths = Install::Paths.new(repo: __dir__, home: Dir.home)
  Install::Installer.new(paths: paths, ruby: Install::RubyInterpreter.path).install
end
