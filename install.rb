#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'rbconfig'
require 'set'
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

    def self.portable(name)
      name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|\-\z/, '')
    end
  end
  # Resolves every source and destination path the installer touches.
  class Paths
    def initialize(repo:, home:)
      @repo = repo
      @home = home
    end

    def scripts              = File.join(@repo, 'scripts')
    def skills_dir           = File.join(@repo, 'skills')
    def bin                  = File.join(@home, '.claude', 'pst', 'bin')
    def skills_root          = File.join(@home, '.claude', 'skills')
    def settings             = File.join(@home, '.claude', 'settings.json')
    def pi_settings          = File.join(@home, '.pi', 'agent', 'settings.json')
    def opencode_config      = File.join(@home, '.config', 'opencode', 'opencode.jsonc')
    def opencode_skills_root = File.join(@home, '.config', 'opencode', 'skills')
    def legacy_pi_roots      = [ File.join(@home, '.pi', 'agent', 'skills'), File.join(@home, '.agents', 'skills') ]
    def pi_extensions_root   = File.join(@home, '.pi', 'agent', 'extensions')
    def pi_extension_source  = File.join(@repo, 'extensions', 'pi-pst-hooks')
    def pi_extension_link    = File.join(pi_extensions_root, 'pst-hooks')

    def scripts_glob         = Dir.glob(File.join(scripts, '*.rb'))
    def skill_sources        = Dir.glob(File.join(skills_dir, '*')).select { |p| File.directory?(p) }
    def script_dest(name)    = File.join(bin, name)
    def skill_link(name)     = File.join(skills_root, name)
    def opencode_skill(name) = File.join(opencode_skills_root, SkillName.portable(name))
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

  # Removes stale Pi/Agent Skills copies now that Claude Code is source of truth.
  class LegacyPiSkillPruner
    def initialize(paths)
      @paths = paths
    end

    def prune
      managed = managed_skill_names
      @paths.legacy_pi_roots.each do |root|
        Dir.glob(File.join(root, '*')).each do |entry|
          FileUtils.rm_rf(entry) if managed.include?(skill_name(entry))
        end
      end
    end

    private

    def managed_skill_names
      @paths.skill_sources.flat_map do |source|
        name = SkillName.of(source)
        [ name, SkillName.portable(name) ]
      end.to_set
    end

    def skill_name(entry)
      path = File.join(entry, 'SKILL.md')
      return unless File.exist?(path)

      front, = SkillRegistry::Frontmatter.split(File.read(path))
      meta = front && YAML.safe_load(front)
      name = meta['name'] if meta.is_a?(Hash)
      name.to_s.empty? ? nil : name.to_s
    rescue StandardError
      nil
    end
  end

  # Adds the Claude Code skill directory to Pi without copying stale skill dirs.
  class PiSettingsFile
    def initialize(path)
      @path = path
    end

    def wire(skill_paths)
      data = load
      paths = Array(data['skills'])
      Array(skill_paths).each { |path| paths << path unless paths.include?(path) }
      data['skills'] = paths
      persist(data)
    end

    private

    def load
      File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError
      {}
    end

    def persist(data)
      FileUtils.mkdir_p(File.dirname(@path))
      FileUtils.cp(@path, "#{@path}.bak") if File.exist?(@path)
      tmp = "#{@path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, @path)
    end
  end

  # Points OpenCode at a generated, OpenCode-safe translation of the same skills.
  # Strips JSONC comments (// line and /* block */) while leaving any
  # comment-like sequences inside string literals untouched. A cursor walks
  # the text and each step is delegated to the current state, so "are we
  # inside a string?" lives in the state objects instead of one wide branch.
  class JsoncStripper
    def self.strip(text) = new(text).strip

    def initialize(text)
      @cursor = Cursor.new(text)
    end

    def strip
      state = Outside
      state = state.step(@cursor) until @cursor.done?
      @cursor.output
    end

    # Holds the scan position and the stripped output, exposing only the
    # moves the states need so the states stay free of index arithmetic.
    class Cursor
      attr_reader :output

      def initialize(text)
        @text = text
        @pos = 0
        @output = String.new
      end

      def done? = @pos >= @text.length
      def peek = @text[@pos]
      def starts?(token) = @text[@pos, token.length] == token

      def keep
        @output << @text[@pos]
        @pos += 1
      end

      def skip_line_comment
        @pos += 2
        @pos += 1 while !done? && peek != "\n"
      end

      def skip_block_comment
        @pos += 2
        @pos += 1 until done? || starts?('*/')
        @pos += 2
      end
    end

    # Default state: copy bytes through, but enter a string or skip a comment
    # when one begins.
    module Outside
      def self.step(cursor)
        if cursor.peek == '"'
          cursor.keep
          Inside
        elsif cursor.starts?('//')
          cursor.skip_line_comment
          self
        elsif cursor.starts?('/*')
          cursor.skip_block_comment
          self
        else
          cursor.keep
          self
        end
      end
    end

    # Inside a string literal: copy every byte verbatim so comment markers are
    # preserved, and treat a backslash as escaping the next byte so an escaped
    # quote does not end the string early.
    module Inside
      def self.step(cursor)
        char = cursor.peek
        cursor.keep
        return Outside if char == '"'
        cursor.keep if char == '\\' && !cursor.done?
        self
      end
    end
  end

  class OpenCodeConfigFile
    def initialize(path)
      @path = path
    end

    def wire(skill_paths)
      data = load
      skills = data['skills'].is_a?(Hash) ? data['skills'] : {}
      paths = Array(skills['paths'])
      Array(skill_paths).each { |path| paths << path unless paths.include?(path) }
      skills['paths'] = paths
      data['skills'] = skills
      persist(data)
    end

    private

    def load
      File.exist?(@path) ? JSON.parse(strip_jsonc(File.read(@path))) : {}
    rescue JSON::ParserError
      {}
    end

    def strip_jsonc(text) = JsoncStripper.strip(text)

    def persist(data)
      FileUtils.mkdir_p(File.dirname(@path))
      FileUtils.cp(@path, "#{@path}.bak") if File.exist?(@path)
      tmp = "#{@path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n")
      File.rename(tmp, @path)
    end
  end

  # OpenCode is stricter about skill names, so pst:foo becomes pst-foo there.
  class OpenCodeSkillMirror
    MARKER = '.pst-generated-from-claude'.freeze
    LEGACY_MARKERS = [ MARKER, '.pst-generated' ].freeze

    def initialize(paths)
      @paths = paths
    end

    def mirror(sources)
      links = sources.to_h { |source| [ @paths.opencode_skill(SkillName.of(source)), source ] }
      prune_stale(links.keys)
      links.each { |dest, source| write_skill(dest, source) }
    end

    private

    def prune_stale(keep)
      Dir.glob(File.join(@paths.opencode_skills_root, '*')).each do |entry|
        next unless generated?(entry) && !keep.include?(entry)

        FileUtils.rm_rf(entry)
      end
    end

    def generated?(entry)
      LEGACY_MARKERS.any? { |marker| File.exist?(File.join(entry, marker)) }
    end

    def write_skill(dest, source)
      return if File.exist?(dest) && !generated?(dest)

      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp_r(source, dest)
      rewrite_frontmatter_name(File.join(dest, 'SKILL.md'), SkillName.portable(SkillName.of(source)))
      File.write(File.join(dest, MARKER), "source: #{source}\n")
    end

    def rewrite_frontmatter_name(path, name)
      front, body = SkillRegistry::Frontmatter.split(File.read(path))
      meta = front && YAML.safe_load(front)
      return unless meta.is_a?(Hash)

      meta['name'] = name
      File.write(path, "---\n#{YAML.dump(meta).sub(/\A---\n/, '')}---\n#{body}")
    rescue StandardError
      nil
    end
  end

  # Top-level orchestration: copies hooks, links skills, and wires settings.
  class Installer
    HOOKS = {
      'SessionStart' => %w[session_start.rb skill_detect.rb],
      'PreToolUse' => %w[merge_mode_guard.rb glyph_guard.rb slop_remind.rb review_gate.rb],
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
      link_pi_extension
      mirror_to_pi
      mirror_to_opencode
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
      links = @paths.skill_sources.to_h { |source| [ @paths.skill_link(SkillName.of(source)), source ] }
      prune_stale_links(links.keys)
      links.each do |link, source|
        FileUtils.mkdir_p(File.dirname(link))
        FileUtils.rm_f(link) if File.symlink?(link)
        FileUtils.ln_sf(source, link)
      end
    end

    def link_pi_extension
      return if File.exist?(@paths.pi_extension_link) && !File.symlink?(@paths.pi_extension_link)

      FileUtils.mkdir_p(@paths.pi_extensions_root)
      FileUtils.rm_f(@paths.pi_extension_link)
      FileUtils.ln_sf(@paths.pi_extension_source, @paths.pi_extension_link)
    end

    # Removes skill symlinks this installer owns - those pointing into the repo's
    # skills dir - that no current source still claims, so a renamed or deleted
    # skill leaves no dangling link. Real dirs and links into other repos are not
    # ours to touch, mirroring how managed_dir scopes the settings sweep.
    def prune_stale_links(keep)
      managed_skill_links.each { |link| FileUtils.rm_f(link) unless keep.include?(link) }
    end

    def managed_skill_links
      Dir.glob(File.join(@paths.skills_root, '*')).select { |entry| points_into_repo_skills?(entry) }
    end

    def points_into_repo_skills?(entry)
      return false unless File.symlink?(entry)

      target = File.expand_path(File.readlink(entry), File.dirname(entry))
      target.start_with?(File.expand_path(@paths.skills_dir) + File::SEPARATOR)
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

    def mirror_to_pi
      LegacyPiSkillPruner.new(@paths).prune
      PiSettingsFile.new(@paths.pi_settings).wire([ @paths.skills_root ])
    end

    def mirror_to_opencode
      OpenCodeSkillMirror.new(@paths).mirror(@paths.skill_sources)
      OpenCodeConfigFile.new(@paths.opencode_config).wire([ @paths.opencode_skills_root ])
    end

    def report(settings)
      skills = @paths.skill_sources.map { |s| SkillName.of(s) }.join(', ')
      puts 'pst shim installed:'
      puts "  hooks    -> #{@paths.bin} (#{HOOKS.keys.join(', ')})"
      puts "  skills   -> #{@paths.skills_root} (#{skills})"
      puts "  pi       -> #{@paths.pi_settings}"
      puts "  pi hooks -> #{@paths.pi_extension_link}"
      puts "  opencode -> #{@paths.opencode_skills_root}"
      puts "  settings -> #{@paths.settings} (backup at #{settings.backup_path})"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  paths = Install::Paths.new(repo: __dir__, home: Dir.home)
  Install::Installer.new(paths: paths, ruby: Install::RubyInterpreter.path).install
end
