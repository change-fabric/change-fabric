#!/usr/bin/env ruby
# frozen_string_literal: true

# Homebrew runs install with no UTF-8 locale; skill files are UTF-8.
Encoding.default_external = Encoding::UTF_8

require 'json'
require 'fileutils'
require 'rbconfig'
require 'set'
require 'yaml'
require_relative 'scripts/skill_registry'
require_relative 'scripts/merge_mode_slug'
require_relative 'scripts/skill_compiler'
require_relative 'scripts/native_hook_install'
require_relative 'scripts/cf_install_manifest'
require_relative 'scripts/cf_ruby_path'
require_relative 'scripts/skill_providers'
require_relative 'scripts/model_roles'
require_relative 'scripts/cf_state'

# Installs the cf merge-mode shim: hook scripts, the skill symlink, and the
# settings.json wiring. Internals are namespaced so the file stays one unit.
module Install
  # Resolves a skill's installed name from its SKILL.md frontmatter `name`, the
  # single source of truth for the `cf:` namespace. Keeping it here means the
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
    def initialize(repo:, home:, xdg_config: nil)
      @repo = repo
      @home = home
      # OpenCode derives its global config dir from XDG_CONFIG_HOME, falling
      # back to ~/.config only when it is unset or empty.
      @xdg_config = xdg_config.to_s.empty? ? File.join(home, '.config') : xdg_config
    end

    def runtime_root = File.join(@home, '.local', 'share', 'change-fabric')
    def runtime_bin = File.join(runtime_root, 'bin')
    def runtime_sources = File.join(runtime_root, 'source-skills')
    def codex_hooks = File.join(@home, '.codex', 'hooks.json')
    def copilot_hooks = File.join(@home, '.copilot', 'hooks', 'change-fabric.json')
    def scripts              = File.join(@repo, 'scripts')
    def skills_dir           = File.join(@repo, 'skills')
    def bin                  = File.join(@home, '.claude', 'cf', 'bin')
    def legacy_bin           = File.join(@home, '.claude', 'pst', 'bin')
    def provider_registry    = File.join(@repo, 'config', 'providers.yml')
    def model_roles_file     = File.join(@repo, 'config', 'model_roles.yml')
    def state_dir            = CfState.root(home: @home)
    def model_roles_user_file = ModelRoles.default_user_file(state_dir)
    def model_roles_snapshot = ModelRoles.default_snapshot_path(state_dir)

    # Every place a script resolves providers.yml from (its own ../config):
    # beside the Claude bin and beside the runtime bin.
    def provider_registry_dests
      [ File.join(state_root, 'config', 'providers.yml'), File.join(runtime_root, 'config', 'providers.yml') ]
    end
    def resource_floors      = File.join(@repo, 'config', 'resource_floors.yml')
    def rule_ids_file        = File.join(@repo, 'config', 'rule_ids.yml')

    # The installed copy is named *.defaults.yml: ~/.claude/cf/config/resource_floors.yml
    # is the user's own override file, which an install must never overwrite.
    def resource_floors_dests
      [ File.join(state_root, 'config', 'resource_floors.defaults.yml'), File.join(runtime_root, 'config', 'resource_floors.defaults.yml') ]
    end
    def state_root           = File.join(@home, '.claude', 'cf')
    def legacy_state_root    = File.join(@home, '.claude', 'pst')
    def skills_root          = File.join(@home, '.claude', 'skills')
    def settings             = File.join(@home, '.claude', 'settings.json')
    def pi_settings          = File.join(@home, '.pi', 'agent', 'settings.json')
    def opencode_root        = File.join(@xdg_config, 'opencode')
    def opencode_config      = File.join(opencode_root, 'opencode.jsonc')
    def opencode_skills_root = File.join(opencode_root, 'skills')
    def copilot_skills_root  = File.join(@home, '.copilot', 'skills')
    def compiled_claude_root = File.join(@home, '.local', 'share', 'change-fabric', 'skills', 'claude')
    def pi_skills_root = File.join(@home, '.pi', 'agent', 'skills')
    def codex_skills_root    = File.join(@home, '.agents', 'skills')
    def codex_skill(name)    = File.join(codex_skills_root, SkillName.portable(name))
    def legacy_pi_roots      = [ File.join(@home, '.pi', 'agent', 'skills') ]
    def pi_extensions_root   = File.join(@home, '.pi', 'agent', 'extensions')
    def pi_extension_source  = File.join(@repo, 'extensions', 'pi-cf-hooks')
    # Copies under the runtime root, never the checkout or a Homebrew Cellar,
    # so the host links survive `brew upgrade` plus `brew cleanup`. `shared` is
    # a sibling because both extensions import ../shared.
    def extensions_copy_root = File.join(runtime_root, 'extensions')
    def pi_extension_copy = File.join(extensions_copy_root, 'pi-cf-hooks')
    def opencode_plugin_copy = File.join(extensions_copy_root, 'opencode-cf-hooks')
    def opencode_extension_source = File.join(@repo, 'extensions', 'opencode-cf-hooks')
    def opencode_plugin_target = File.join(opencode_plugin_copy, 'index.ts')
    def shared_extension_source = File.join(@repo, 'extensions', 'shared')
    def shared_extension_copy = File.join(extensions_copy_root, 'shared')
    def extension_backups_root = File.join(runtime_root, 'backups')
    def pi_extension_link    = File.join(pi_extensions_root, 'cf-hooks')
    def opencode_plugins_root   = File.join(opencode_root, 'plugins')
    def opencode_plugin_source  = File.join(@repo, 'extensions', 'opencode-cf-hooks', 'index.ts')
    # OpenCode loads only plugins/*.{ts,js}, never a nested directory.
    def opencode_plugin_link    = File.join(opencode_plugins_root, 'cf-hooks.ts')

    # Top-level scripts plus the JS helpers they read by __dir__ (the
    # walkthrough easing and element runtimes), installed side by side so the
    # manifest, prune, and runtime copy all cover them.
    def scripts_glob         = Dir.glob(File.join(scripts, '*.{rb,js}'))
    # Assets a script reads at run time rather than requires: today the pinned
    # axe-core bundle the a11y lane injects instead of fetching from a CDN.
    # They install beside the scripts, keeping `__dir__`-relative lookups
    # working identically from the repo and from the installed copy.
    def vendor               = File.join(scripts, 'vendor')
    def vendor_glob          = Dir.glob(File.join(vendor, '**', '*')).select { |path| File.file?(path) }
    def vendor_dest(source, root = bin) = File.join(root, 'vendor', source.delete_prefix("#{vendor}/"))
    # Library folders a script requires (scripts/secret_intake/*.rb). They
    # install under the same relative path so require_relative resolves alike.
    def lib_glob = Dir.glob(File.join(scripts, '*', '**', '*.rb')).reject { |path| path.start_with?("#{vendor}/") }
    def lib_dest(source, root = bin) = File.join(root, source.delete_prefix("#{scripts}/"))
    def skill_sources        = Dir.glob(File.join(skills_dir, '*')).select { |p| File.directory?(p) }
    def script_dest(name)    = File.join(bin, name)
    def manifest             = File.join(bin, '.installed-manifest')
    def skill_link(name)     = File.join(skills_root, name)
    def opencode_skill(name) = File.join(opencode_skills_root, SkillName.portable(name))
    def copilot_skill(name)  = File.join(copilot_skills_root, SkillName.portable(name))
  end

  # Resolves the absolute path of the running Ruby interpreter for hook shebangs.
  module RubyInterpreter
    def self.path
      resolved = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
      raise 'could not resolve a ruby interpreter' unless File.executable?(resolved)

      CfRubyPath.stable(resolved)
    end
  end

  # Copies one extension directory into the runtime root without ever deleting
  # a file the user changed. The new copy is staged beside the old one; any file
  # in the old copy whose sha256 differs from the previous installation.json, or
  # that it never recorded, moves to a timestamped backup before the swap.
  class ExtensionCopy
    def initialize(source:, dest:, label:, backup_dir:, manifest:)
      @source = source
      @dest = dest
      @label = label
      @backup_dir = backup_dir
      @manifest = manifest
    end

    def sync
      stage = "#{@dest}.new-#{Process.pid}"
      stage_copy(stage)
      back_up_user_files
      FileUtils.rm_rf(@dest)
      File.rename(stage, @dest)
    end

    private

    def stage_copy(stage)
      FileUtils.rm_rf(stage)
      FileUtils.mkdir_p(File.dirname(@dest))
      FileUtils.cp_r(@source, stage)
    rescue StandardError => e
      FileUtils.rm_rf(stage)
      raise "could not stage #{@label} into #{File.dirname(@dest)}: #{e.message}"
    end

    def back_up_user_files
      return unless File.symlink?(@dest) || File.exist?(@dest)

      files = File.directory?(@dest) && !File.symlink?(@dest) ? old_files : [ @dest ]
      moved = files.reject { |path| installer_owned?(path) }.map { |path| move_to_backup(path) }
      warn "  cf: backed up #{moved.size} edited or added file(s) under #{File.join(@backup_dir, @label)}" unless moved.empty?
    end

    def old_files
      Dir.glob(File.join(@dest, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) || File.symlink?(path) }
    end

    def installer_owned?(path)
      return false if File.symlink?(path)

      recorded = @manifest.recorded(path)
      !recorded.nil? && recorded['sha256'] == Digest::SHA256.file(path).hexdigest
    end

    def move_to_backup(path)
      target = File.join(@backup_dir, @label, path == @dest ? File.basename(path) : path.delete_prefix("#{@dest}/"))
      target = "#{target}.#{Process.pid}-#{rand(36**4).to_s(36)}" while File.exist?(target) || File.symlink?(target)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.mv(path, target)
      warn "  cf: #{path} was edited or not installed by cf; moved to #{target}"
      target
    end
  end

  # Wires managed hooks into ~/.claude/settings.json idempotently, with a backup.
  # `managed_dir` is the current bin; `legacy_dirs` are prior bins (a former
  # ~/.claude/pst/bin from before the cf rename) whose stale entries must be
  # swept on the same run that adds the current ones, or every hook fires twice.
  class SettingsFile
    def initialize(path, managed_dir:, legacy_dirs: [])
      @path = path
      @managed_dirs = ([ managed_dir ] + Array(legacy_dirs)).uniq
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
        Array(commands).each do |entry|
          command, matcher, timeout = entry.is_a?(Hash) ? entry.values_at('command', 'matcher', 'timeout') : [ entry, nil, nil ]
          hook = { 'type' => 'command', 'command' => command }
          hook['timeout'] = timeout if timeout
          group = { 'hooks' => [ hook ] }
          group = { 'matcher' => matcher }.merge(group) if matcher
          section << group
        end
      end
    end

    def drop_managed_hooks(section)
      section.each { |group| remove_managed_from_group(group) }
      section.reject! { |group| group.is_a?(Hash) && (group['hooks'] || []).empty? }
    end

    def remove_managed_from_group(group)
      return unless group.is_a?(Hash) && group['hooks'].is_a?(Array)

      group['hooks'].reject! do |hook|
        command = hook['command'].to_s
        @managed_dirs.any? { |dir| command.include?(dir) }
      end
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
          owned = PortableSkillMirror::LEGACY_MARKERS.any? { |marker| File.file?(File.join(entry, marker)) }
          FileUtils.rm_rf(entry) if owned && managed.include?(skill_name(entry))
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

    # retire names paths an earlier installer wired and this one no longer
    # manages; they are removed exactly, leaving user-added paths alone.
    def wire(skill_paths, retire: [])
      data = load
      retired = Array(retire).map { |path| File.expand_path(path) }
      paths = Array(data['skills']).reject { |path| path.is_a?(String) && retired.include?(File.expand_path(path)) }
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

    def wire(skill_paths, remove_paths: [])
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

  # OpenCode and Copilot are stricter about skill names, so cf:foo becomes
  # cf-foo there. Subclasses name the destination root and per-skill path.
  class PortableSkillMirror
    MARKER = '.cf-generated-from-claude'.freeze
    # Recognize the current marker plus the pre-rename markers so mirrors from a
    # prior pst-branded install are still spotted and pruned.
    LEGACY_MARKERS = [ MARKER, '.pst-generated-from-claude', '.pst-generated' ].freeze

    # roles is {host => {role => model}}; a host with no entry renders the
    # host-neutral phrasing.
    def initialize(paths, roles = {})
      @paths = paths
      @roles = roles
    end

    def mirror(sources)
      links = sources.to_h { |source| [ skill_path(SkillName.of(source)), source ] }
      prune_stale(links.keys)
      links.each { |dest, source| write_skill(dest, source) }
    end

    private

    def prune_stale(keep)
      Dir.glob(File.join(skills_root, '*')).each do |entry|
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
      compiler = SkillCompiler.new(host: host, workflows: File.join(File.dirname(@paths.skills_dir), 'workflows', 'modes'),
                                   roles: @roles[host])
      Dir.glob(File.join(dest, '**', '*.md')).each do |path|
        text = File.read(path)
        rendered = path == File.join(dest, 'SKILL.md') ? compiler.compile(text) : compiler.references(text)
        File.write(path, rendered)
      end
      Dir.glob(File.join(dest, '**', '*.js')).each do |path|
        text = File.read(path)
        rendered = compiler.render_model_js(text)
        File.write(path, rendered) unless rendered == text
      end
      File.write(File.join(dest, MARKER), "source: #{source.delete_prefix("#{File.dirname(@paths.skills_dir)}/")}\n")
    end

    def host = raise NotImplementedError
  end

  class ClaudeSkillMirror < PortableSkillMirror
    private

    def host = 'claude'
    def skills_root = @paths.compiled_claude_root
    def skill_path(name) = File.join(skills_root, name)
  end

  class PiSkillMirror < PortableSkillMirror
    private

    def host = 'pi'
    def skills_root = @paths.pi_skills_root
    def skill_path(name) = File.join(skills_root, SkillName.portable(name))
  end

  class OpenCodeSkillMirror < PortableSkillMirror
    private

    def host = 'opencode'
    def skills_root = @paths.opencode_skills_root
    def skill_path(name) = @paths.opencode_skill(name)
  end

  class CopilotSkillMirror < PortableSkillMirror
    private

    def host = 'copilot'
    def skills_root = @paths.copilot_skills_root
    def skill_path(name) = @paths.copilot_skill(name)
  end

  class CodexSkillMirror < PortableSkillMirror
    private

    def host = 'codex'
    def skills_root = @paths.codex_skills_root
    def skill_path(name) = @paths.codex_skill(name)
  end

  class Installer
    HOOKS = {
      'SessionStart' => %w[skill_detect.rb ctx_session_start.rb doctrine_digest.rb secret_alert_poll.rb],
      'PreToolUse' => %w[secrets_read_guard.rb force_push_guard.rb client_name_guard.rb slop_remind.rb review_gate.rb noreply_guard.rb docker_doctrine_guard.rb change_merge_guard.rb change_tag_guard.rb change_stale_remind.rb approval_watch_remind.rb presence_probe.rb prod_approval_guard.rb model_role_guard.rb resource_floor_guard.rb glyph_guard.rb],
      'PostToolUse' => %w[skill_inject.rb secret_ack.rb change_post_merge_check.rb],
      'UserPromptSubmit' => %w[key_paste_guard.rb prune_remind.rb inbox_prompt_hook.rb],
      'SessionEnd' => %w[telemetry_emit.rb inbox_session_end.rb],
      'Stop' => %w[skill_review.rb doctrine_review_surface.rb]
    }.freeze

    # Tool matcher per PreToolUse and PostToolUse script. Deny guards err wide:
    # a matcher that is too narrow silently disables a guard, one that is too
    # wide only costs a no-op evaluation (the script re-checks the tool itself).
    SHELL = 'Bash'
    FILE_EDITS = 'Edit|Write|MultiEdit|NotebookEdit'
    MATCHERS = {
      'secrets_read_guard.rb' => "Bash|Read|Grep|Glob|#{FILE_EDITS}",
      'force_push_guard.rb' => SHELL,
      'client_name_guard.rb' => "Bash|#{FILE_EDITS}|mcp__.*",
      'slop_remind.rb' => SHELL,
      'glyph_guard.rb' => 'Bash|Write|Edit',
      'review_gate.rb' => SHELL,
      'noreply_guard.rb' => SHELL,
      'docker_doctrine_guard.rb' => SHELL,
      'change_merge_guard.rb' => SHELL,
      'change_tag_guard.rb' => SHELL,
      'change_stale_remind.rb' => SHELL,
      'approval_watch_remind.rb' => SHELL,
      'presence_probe.rb' => FILE_EDITS,
      'prod_approval_guard.rb' => SHELL,
      'model_role_guard.rb' => 'Agent|Task',
      'resource_floor_guard.rb' => 'Agent|Task',
      'skill_inject.rb' => FILE_EDITS,
      'secret_ack.rb' => 'AskUserQuestion',
      'change_post_merge_check.rb' => SHELL
    }.freeze

    # Seconds a hook may run. Only the review gate sets one: stage 1 runs the
    # repo's own linters and tests (900s each by default), far past the host's
    # default hook limit.
    TIMEOUTS = { 'review_gate.rb' => 3600 }.freeze

    def initialize(paths:, ruby:)
      @paths = paths
      @ruby = ruby
    end

    def install
      # First, so an unknown provider fails the install before anything moves.
      @required_providers = SkillProviders.collect(@paths.skill_sources)
      resolve_model_roles
      migrate_state_root
      migrate_merge_mode_slugs
      place_hooks
      place_runtime
      pin_expected_home
      link_skills
      copy_extensions
      link_pi_extension
      link_opencode_plugin
      mirror_to_codex
      mirror_to_pi
      mirror_to_opencode
      mirror_to_copilot
      settings = wire_settings
      wire_native_hooks
      place_launcher
      record_installation
      write_model_roles_snapshot
      report(settings)
    end

    private

    # The snapshot host: the host whose resolved table the hook and grader read.
    SNAPSHOT_HOST = 'claude'

    # Resolve the whole map once (env > user file > repo, validated), before
    # anything moves, so a bad model string fails the install and every skill
    # compiles from the same in-memory table the snapshot will record.
    def resolve_model_roles
      options = { env: ENV, user_file: @paths.model_roles_user_file, repo_file: @paths.model_roles_file }
      @role_tables = SkillCompiler::HOSTS.to_h { |host| [ host, ModelRoles.table(host: host, **options) ] }
      @role_sources = ModelRoles.sources(host: SNAPSHOT_HOST, **options)
      drift = ModelRoles.drift(host: SNAPSHOT_HOST, path: @paths.model_roles_snapshot, **options)
      puts ModelRoles.drift_message(drift, applying: true) unless drift.empty?
    end

    # Last, and atomic, so a failed compile leaves the old snapshot in place.
    def write_model_roles_snapshot
      roles = @role_tables[SNAPSHOT_HOST]
      return unless roles

      ModelRoles.write_snapshot(host: SNAPSHOT_HOST, roles: roles, sources: @role_sources, path: @paths.model_roles_snapshot)
    end

    # Best-effort carry-over of the state root from the pre-rename location so a
    # prior install's sessions/ctx/change/teams/telemetry survive the cf rename.
    # Only acts when the old root exists and the new one does not; if both exist
    # it leaves both untouched rather than attempting a merge. Runs before
    # place_hooks so the moved tree is in place before anything writes into it.
    def migrate_state_root
      legacy = @paths.legacy_state_root
      current = @paths.state_root
      return unless File.directory?(legacy)

      if File.exist?(current)
        puts "note: both #{legacy} and #{current} exist; leaving both in place, no migration"
        return
      end

      FileUtils.mkdir_p(File.dirname(current))
      FileUtils.mv(legacy, current)
      puts "migrated state root #{legacy} -> #{current}"
    end

    # Rewrites any session merge-mode file still holding a legacy
    # AskUserQuestion label ("Local only") into the canonical slug
    # ("local-only"). Idempotent by construction: a file already holding the
    # slug normalizes to itself and is skipped, so this self-heals on every
    # re-run and on every machine. Unrecognized content is left untouched
    # rather than guessed at.
    def migrate_merge_mode_slugs
      migrated = 0
      skipped = 0
      Dir.glob(File.join(@paths.state_root, 'sessions', '*', 'merge-mode')).each do |file|
        raw = File.read(file).strip
        slug = MergeModeSlug.of(raw)
        if slug.nil?
          skipped += 1
        elsif slug != raw
          File.write(file, "#{slug}\n")
          migrated += 1
        end
      end
      return if migrated.zero? && skipped.zero?

      puts "migrated #{migrated} merge-mode file(s) to slug format (#{skipped} unrecognized, left as-is)"
    rescue StandardError => e
      puts "note: merge-mode slug migration skipped (#{e.class})"
    end

    # Reconciles bin/ against this run's script set rather than clearing the
    # whole directory: bin/ is a fixed, well-known path
    # (~/.claude/cf/bin), and a prior rm_rf here destroyed a user's own
    # unrelated script that happened to live there too. Only files this
    # installer itself wrote on a previous run (tracked in the manifest) are
    # removed when they drop out of the current script set; anything else in
    # the directory is left alone.
    def place_hooks
      FileUtils.mkdir_p(@paths.bin)
      names = @paths.scripts_glob.map { |source| File.basename(source) }.to_set
      remove_stale_managed_scripts(names)
      @paths.scripts_glob.each do |source|
        dest = @paths.script_dest(File.basename(source))
        FileUtils.cp(source, dest)
        FileUtils.chmod(source.end_with?('.rb') ? 0o755 : 0o644, dest)
      end
      place_vendor
      place_libs
      place_provider_registry
      write_manifest(names)
    end

    def place_provider_registry
      @paths.provider_registry_dests.each do |dest|
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(@paths.provider_registry, dest)
        # Beside it, so scripts/model_roles.rb finds the repo map from a runtime copy.
        FileUtils.cp(@paths.model_roles_file, File.join(File.dirname(dest), 'model_roles.yml'))
        # Beside it too: scripts/hook_event.rb reads the declared rule IDs from ../config.
        FileUtils.cp(@paths.rule_ids_file, File.join(File.dirname(dest), 'rule_ids.yml'))
      end
      @paths.resource_floors_dests.each do |dest|
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(@paths.resource_floors, dest)
      end
    end

    def remove_stale_managed_scripts(current_names)
      previous_names(@paths.manifest).each do |name|
        next if current_names.include?(name)

        FileUtils.rm_f(@paths.script_dest(name))
      end
    end

    def previous_names(manifest)
      return [] unless File.exist?(manifest)

      File.read(manifest).each_line.map(&:strip).reject(&:empty?)
    rescue StandardError
      []
    end

    def write_manifest(names)
      File.write(@paths.manifest, "#{names.to_a.sort.join("\n")}\n")
    end

    # Run-time assets, not executables: copied without the 0755 the scripts get.
    # Both script dirs get them: hooks and the cf launcher run the runtime
    # copy, whose __dir__-relative lookups (the walkthrough cursor, axe-core)
    # otherwise found nothing.
    def place_vendor(root = @paths.bin)
      @paths.vendor_glob.each do |source|
        dest = @paths.vendor_dest(source, root)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(source, dest)
      end
    end

    def place_libs(root = @paths.bin)
      @paths.lib_glob.each do |source|
        dest = @paths.lib_dest(source, root)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(source, dest)
      end
    end

    # Records this device's home beside the installed scripts so ctx_paths keys
    # the store and catches a wrong runtime HOME without the repo naming an
    # absolute user path. Written after place_hooks, which wipes the bin dir, and
    # read via __dir__ so it survives a session launched with a divergent HOME.
    def pin_expected_home
      File.write(File.join(@paths.bin, '.expected-home'), Dir.home)
    end

    def link_skills
      ClaudeSkillMirror.new(@paths, @role_tables).mirror(@paths.skill_sources)
      links = @paths.skill_sources.to_h do |source|
        name = SkillName.of(source)
        [ @paths.skill_link(name), File.join(@paths.compiled_claude_root, name) ]
      end
      prune_stale_links(links.keys)
      links.each do |link, source|
        next if File.exist?(link) && !points_into_repo_skills?(link)

        FileUtils.mkdir_p(File.dirname(link))
        FileUtils.rm_f(link) if File.symlink?(link)
        FileUtils.ln_sf(source, link)
      end
    end

    def copy_extensions
      backup_dir = File.join(@paths.extension_backups_root, "extensions-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
      [ [ @paths.pi_extension_source, @paths.pi_extension_copy, 'pi-cf-hooks' ],
        [ @paths.opencode_extension_source, @paths.opencode_plugin_copy, 'opencode-cf-hooks' ],
        [ @paths.shared_extension_source, @paths.shared_extension_copy, 'shared' ] ].each do |source, dest, label|
        ExtensionCopy.new(source: source, dest: dest, label: label, backup_dir: backup_dir, manifest: install_manifest).sync
      end
    end

    def link_pi_extension
      link_extension(@paths.pi_extension_link, @paths.pi_extensions_root, @paths.pi_extension_copy, 'extensions/pi-cf-hooks')
    end

    def link_opencode_plugin
      link_extension(@paths.opencode_plugin_link, @paths.opencode_plugins_root, @paths.opencode_plugin_target,
                     'extensions/opencode-cf-hooks/index.ts')
    end

    def link_extension(link, root, target, legacy_suffix)
      return if File.exist?(link) && !File.symlink?(link)
      return warn "  cf: #{link} points elsewhere; left alone (wanted #{target})" unless replaceable_link?(link, target, legacy_suffix)

      FileUtils.mkdir_p(root)
      FileUtils.rm_f(link)
      FileUtils.ln_sf(target, link)
    end

    # A link is ours to repoint when it is absent, already right, recorded by an
    # earlier install, or aims at an extension dir of a checkout or Cellar.
    def replaceable_link?(link, target, legacy_suffix)
      return true unless File.symlink?(link)

      current = File.readlink(link)
      recorded = install_manifest.recorded(link)
      current == target || recorded&.fetch('link', nil) == current || current.end_with?("/#{legacy_suffix}")
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
      [ @paths.skills_dir, @paths.compiled_claude_root ].any? do |root|
        target.start_with?(File.expand_path(root) + File::SEPARATOR)
      end
    end

    def place_runtime
      FileUtils.mkdir_p(@paths.runtime_bin)
      @paths.scripts_glob.each do |source|
        FileUtils.cp(source, File.join(@paths.runtime_bin, File.basename(source)))
      end
      place_vendor(@paths.runtime_bin)
      place_libs(@paths.runtime_bin)
      config = File.join(@paths.runtime_root, 'config')
      FileUtils.mkdir_p(config)
      FileUtils.cp(File.join(File.dirname(@paths.skills_dir), 'config', 'host_capabilities.json'), config)
      FileUtils.mkdir_p(@paths.runtime_sources)
      @paths.skill_sources.each do |source|
        dest = File.join(@paths.runtime_sources, File.basename(source))
        FileUtils.mkdir_p(dest)
        FileUtils.cp(File.join(source, 'SKILL.md'), dest)
      end
    end

    def place_launcher
      # runtime_root is ~/.local/share/change-fabric; launcher is ~/.local/bin/cf.
      path = File.expand_path('../../bin/cf', @paths.runtime_root)
      marker = '# change-fabric managed launcher'
      return if File.symlink?(path)
      return if File.exist?(path) && !File.read(path).include?(marker)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#!/usr/bin/env ruby\n#{marker}\nexec(#{@ruby.dump}, #{File.join(@paths.runtime_bin, 'cf_cli.rb').dump}, *ARGV)\n")
      FileUtils.chmod(0o755, path)
    end

    def record_installation
      files = @paths.scripts_glob.flat_map do |source|
        [ @paths.script_dest(File.basename(source)), File.join(@paths.runtime_bin, File.basename(source)) ]
      end
      files.concat(@paths.vendor_glob.flat_map { |source| [ @paths.vendor_dest(source), @paths.vendor_dest(source, @paths.runtime_bin) ] })
      files.concat(@paths.lib_glob.flat_map { |source| [ @paths.lib_dest(source), @paths.lib_dest(source, @paths.runtime_bin) ] })
      files << File.join(@paths.runtime_root, 'config', 'host_capabilities.json')
      files.concat(@paths.provider_registry_dests)
      files.concat(@paths.resource_floors_dests)
      files << File.expand_path('../../bin/cf', @paths.runtime_root)
      files << @paths.manifest
      files << File.join(@paths.bin, '.expected-home')
      roots = [ @paths.compiled_claude_root, @paths.pi_skills_root, @paths.opencode_skills_root,
                @paths.copilot_skills_root, @paths.codex_skills_root ]
      roots.each do |root|
        Dir.glob(File.join(root, '*')).each do |dir|
          next unless PortableSkillMirror::LEGACY_MARKERS.any? { |marker| File.file?(File.join(dir, marker)) }

          files.concat(Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH).select { |file| File.file?(file) })
        end
      end
      files.concat(@paths.skill_sources.map { |source| File.join(@paths.runtime_sources, File.basename(source), 'SKILL.md') })
      @paths.skill_sources.each do |source|
        link = @paths.skill_link(SkillName.of(source))
        files << link if points_into_repo_skills?(link)
      end
      [ @paths.pi_extension_copy, @paths.opencode_plugin_copy, @paths.shared_extension_copy ].each do |dir|
        files.concat(Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH).select { |file| File.file?(file) })
      end
      [ [ @paths.pi_extension_link, @paths.pi_extension_copy ], [ @paths.opencode_plugin_link, @paths.opencode_plugin_target ] ].each do |link, target|
        files << link if File.symlink?(link) && File.readlink(link) == target
      end
      launcher = File.expand_path('../../bin/cf', @paths.runtime_root)
      files.delete(launcher) unless File.file?(launcher) && !File.symlink?(launcher) && File.read(launcher).include?('# change-fabric managed launcher')
      install_manifest.record(files, 'required_providers' => @required_providers)
    end

    def install_manifest
      home = File.expand_path('../../..', @paths.runtime_root)
      CfInstallManifest.new(path: File.join(@paths.runtime_root, 'installation.json'), home: home)
    end

    def wire_native_hooks
      [ [ 'claude', @paths.settings ], [ 'codex', @paths.codex_hooks ], [ 'copilot', @paths.copilot_hooks ] ].each do |host, path|
        NativeHookInstall.new(path: path, host: host, ruby: @ruby, bin: @paths.runtime_bin, backup: host != 'claude').wire
      end
    end

    def wire_settings
      settings = SettingsFile.new(@paths.settings, managed_dir: @paths.bin, legacy_dirs: [ @paths.legacy_bin, @paths.runtime_bin ])
      settings.wire(commands)
      settings
    end

    def commands
      HOOKS.to_h do |event, names|
        [ event, names.map { |name| hook_entry(event, name) } ]
      end
    end

    # A PreToolUse or PostToolUse entry carries its matcher; the rest stay strings.
    def hook_entry(event, name)
      command = "#{@ruby} #{@paths.script_dest(name)}"
      return command unless %w[PreToolUse PostToolUse].include?(event)

      { 'command' => command, 'matcher' => MATCHERS.fetch(name), 'timeout' => TIMEOUTS[name] }.compact
    end

    def mirror_to_pi
      LegacyPiSkillPruner.new(@paths).prune
      PiSkillMirror.new(@paths, @role_tables).mirror(@paths.skill_sources)
      shared_copies = @paths.skill_sources.filter_map do |source|
        path = @paths.codex_skill(SkillName.of(source))
        next unless PortableSkillMirror::LEGACY_MARKERS.any? { |marker| File.file?(File.join(path, marker)) }

        "-#{File.join(path, 'SKILL.md')}"
      end
      PiSettingsFile.new(@paths.pi_settings).wire([ @paths.pi_skills_root, *shared_copies ], retire: [ @paths.skills_root ])
    end

    def mirror_to_opencode
      OpenCodeSkillMirror.new(@paths, @role_tables).mirror(@paths.skill_sources)
      OpenCodeConfigFile.new(@paths.opencode_config).wire([ @paths.opencode_skills_root ])
    end

    def mirror_to_copilot
      CopilotSkillMirror.new(@paths, @role_tables).mirror(@paths.skill_sources)
    end

    def mirror_to_codex
      CodexSkillMirror.new(@paths, @role_tables).mirror(@paths.skill_sources)
    end

    def report(settings)
      skills = @paths.skill_sources.map { |s| SkillName.of(s) }.join(', ')
      puts 'cf shim installed:'
      puts "  hooks    -> #{@paths.bin} (#{HOOKS.keys.join(', ')})"
      puts "  skills   -> #{@paths.skills_root} (#{skills})"
      puts "  pi       -> #{@paths.pi_settings}"
      puts "  pi hooks -> #{@paths.pi_extension_link}"
      puts "  opencode -> #{@paths.opencode_skills_root}"
      puts "  opencode hooks -> #{@paths.opencode_plugin_link}"
      puts "  copilot  -> #{@paths.copilot_skills_root}"
      puts "  codex    -> #{@paths.codex_skills_root} (invoke with $cf-merge-ready or /skills; review hooks with /hooks)"
      puts "  runtime  -> #{@paths.runtime_bin} (state: ~/.local/state/change-fabric)"
      puts "  codex hooks -> #{@paths.codex_hooks} (host trust/configuration still applies)"
      puts "  copilot hooks -> #{@paths.copilot_hooks} (CLI only)"
      puts "  settings -> #{@paths.settings} (backup at #{settings.backup_path})"
      puts "  #{SkillProviders.report(@required_providers)}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  paths = Install::Paths.new(repo: __dir__, home: Dir.home, xdg_config: ENV.fetch('XDG_CONFIG_HOME', nil))
  begin
    ruby = Install::RubyInterpreter.path
  rescue CfRubyPath::UnstableInterpreter => e
    warn "cf install: #{e.message}"
    exit 1
  end
  Install::Installer.new(paths: paths, ruby: ruby).install
end
