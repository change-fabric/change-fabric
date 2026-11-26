#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'shellwords'
require 'securerandom'
require 'pathname'
require 'yaml'
require 'json'
require_relative 'change_process'
require_relative 'change_config'
require_relative 'change_env'
require_relative 'change_trust'
require_relative 'change_frontmatter'
require_relative 'plan_check'
require_relative 'skill_registry'

# Stage 1 of the two-stage review gate: deterministic checks that run before any
# model. The repo's own linters and tests, the glyph check and the existing
# greps. Each check ends in one of five states:
#
#   passed          ran, exit 0                                   no block
#   failed          ran, non-zero, findings with file:line        blocks
#   unavailable     required here but tool or config is missing   blocks
#   not_applicable  detector finds no stack source or manifest    no block
#   timed_out       exceeded its timeout                          blocks
#
# Detectors key off the stack (source files and manifests), never off whether
# the enforcer is installed: a present stack with a missing enforcer is
# `unavailable`, which blocks, so a rule never silently stops being enforced.
# Test and lint commands come from the CHANGE.md command lane first; without
# one, the matching manifest decides (`bundle exec rake test`, `pnpm test`,
# `npm test`).
module ReviewStage1
  STATUSES = %w[passed failed unavailable not_applicable timed_out].freeze
  BLOCKING = %w[failed unavailable timed_out].freeze
  # Constant until the unified loop caps land (config/loop_caps.yml).
  DEFAULT_TIMEOUT = 300
  MAX_FINDINGS = 20
  SKIP_DIRS = %w[node_modules vendor tmp dist build coverage log fixtures].freeze
  JS_EXTENSIONS = %w[js mjs cjs jsx].freeze
  SOURCE_EXTENSIONS = %w[js mjs cjs jsx ts tsx mts vue svelte html].freeze
  ACTIONLINT_IMAGE = 'rhysd/actionlint:1.7.7'
  ZIZMOR_IMAGE = 'ghcr.io/zizmorcore/zizmor:1.5.2'
  # Warnings block too: a rule accepted as an enforcer at warn level must fail the run.
  ESLINT = 'npx --no-install eslint . --max-warnings 0'
  TS_EXTENSIONS = %w[ts tsx mts cts].freeze
  NPM_PLACEHOLDER_TEST = /no test specified/
  RUBOCOP = 'bundle exec rubocop --format emacs'

  Result = Struct.new(:id, :status, :detail, :command, :findings, keyword_init: true) do
    def blocking? = BLOCKING.include?(status)
  end

  Report = Struct.new(:results) do
    def blocking = results.select(&:blocking?)
    def blocking? = !blocking.empty?

    def to_text
      lines = [ "[cf review] Stage 1 blocked the push: #{blocking.size} of #{results.size} check(s). " \
                'Fix these before the model review runs.' ]
      blocking.each { |result| lines.concat(result_lines(result)) }
      lines.join("\n")
    end

    private

    def result_lines(result)
      head = "- #{result.status} #{result.id}"
      head += " (#{result.command})" if result.command
      [ head, "    #{result.detail}", *Array(result.findings).map { |finding| "    #{finding}" } ]
    end
  end

  # The repo under review: file lookups pruned the way SkillRegistry prunes.
  class Repo
    attr_reader :root

    def initialize(root)
      @root = root
    end

    def file?(rel) = File.file?(File.join(root, rel))
    def read(rel) = file?(rel) ? File.read(File.join(root, rel)) : ''
    def glob(pattern) = Dir.glob(File.join(root, pattern)).map { |path| path.delete_prefix("#{root}/") }

    def deps
      # Fixture, vendored and build-output manifests are not the repo's own stack.
      @deps ||= SkillRegistry.manifests(root).reject { |path| own_manifest?(path) == false }
                             .filter_map { |path| SkillRegistry.dep_keys(path) }.flatten.uniq
    end

    def dep?(name) = deps.include?(name)

    def own_manifest?(path) = (path.delete_prefix("#{root}/").split('/') & SKIP_DIRS).empty?

    # Every file under root with one of the extensions, dot dirs and
    # dependency dirs pruned. Capped so a huge tree cannot stall a hook.
    def sources(extensions, limit: 20_000)
      found = []
      walk(root, extensions, found, limit)
      found
    end

    def eslint_config
      @eslint_config ||= begin
        files = glob('eslint.config.*') + glob('.eslintrc*')
        text = files.map { |rel| read(rel) }.join("\n")
        text + eslint_in_package
      end
    end

    # Whether the repo has opted into a tool: its config file or declared
    # dependency exists. A repo that never adopted a tool is not denied for it.
    def adopted?(tool)
      case tool
      when :eslint then !eslint_config.strip.empty? || dep?('eslint')
      when :rubocop then file?('.rubocop.yml') || %w[Gemfile Gemfile.lock].any? { |rel| read(rel).match?(/\brubocop\b/) }
      else true
      end
    end

    def git_head
      out, status = Open3.capture2e('git', '-C', root, 'rev-parse', 'HEAD')
      status.success? ? out.strip : 'HEAD'
    rescue SystemCallError
      'HEAD'
    end

    def rails? = file?('config/application.rb') || read('Gemfile.lock').match?(/^\s+rails \(/)

    private

    def eslint_in_package
      pkg = JSON.parse(read('package.json'))
      pkg.is_a?(Hash) && pkg['eslintConfig'] ? JSON.generate(pkg['eslintConfig']) : ''
    rescue JSON::ParserError
      ''
    end

    def walk(dir, extensions, found, limit)
      Dir.children(dir).sort.each do |name|
        break if found.size >= limit

        path = File.join(dir, name)
        next if name.start_with?('.') || SKIP_DIRS.include?(name) || File.symlink?(path)

        if File.directory?(path)
          walk(path, extensions, found, limit)
        elsif extensions.include?(File.extname(name).delete_prefix('.').downcase)
          found << path.delete_prefix("#{root}/")
        end
      end
    rescue SystemCallError
      nil
    end
  end

  # Resolves compilerOptions.strict through a tsconfig `extends` chain: relative
  # files and packages under node_modules, an array of bases (later wins).
  # Returns [value, error]; error names what could not be resolved.
  module TsConfig
    MAX_DEPTH = 10
    module_function

    def strict(repo, rel = 'tsconfig.json', seen = [])
      return [ nil, "tsconfig extends chain is cyclic or deeper than #{MAX_DEPTH} at #{rel}" ] if seen.include?(rel) || seen.size > MAX_DEPTH

      data = parse(repo.read(rel))
      return [ nil, "#{rel} is not readable JSON" ] unless data.is_a?(Hash)

      own = data.dig('compilerOptions', 'strict') if data['compilerOptions'].is_a?(Hash)
      return [ own, nil ] unless own.nil?

      inherit(repo, rel, Array(data['extends']), seen)
    end

    def inherit(repo, rel, bases, seen)
      value = nil
      bases.each do |ref|
        path = locate(repo, rel, ref.to_s)
        return [ nil, "cannot resolve tsconfig extends #{ref.inspect} from #{rel} (install dependencies)" ] unless path

        found, error = strict(repo, path, seen + [ rel ])
        return [ nil, error ] if error

        value = found unless found.nil?
      end
      [ value, nil ]
    end

    def parse(text)
      plain = text.gsub(%r{("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/}m) { Regexp.last_match(1) || '' }
      JSON.parse(plain.gsub(/,(\s*[}\]])/, '\1'))
    rescue JSON::ParserError
      nil
    end

    def locate(repo, rel, ref)
      here = File.dirname(rel)
      candidates = ref.start_with?('.') ? [ File.join(here, ref) ] : ancestors(here).map { |dir| File.join(dir, 'node_modules', ref) }
      candidates.flat_map { |base| [ base, "#{base}.json", File.join(base, 'tsconfig.json') ] }
                .map { |path| Pathname.new(path).cleanpath.to_s }
                .find { |path| !path.start_with?('..') && repo.file?(path) }
    end

    def ancestors(dir)
      dir == '.' ? [ '.' ] : [ dir ] + ancestors(File.dirname(dir))
    end
  end

  # One row of the migration table. `commands` run in order through the runner;
  # `native` replaces them with an in-process scan. `missing` returns the exact
  # config to add, or nil when the enforcer is in place.
  Check = Struct.new(:id, :detect, :missing, :commands, :native, :tool, keyword_init: true)

  # Runs one stage 1 pass over a repo root.
  class Run
    # runner: (command, root, timeout) -> ChangeProcess::Result. which: tool
    # lookup. files: changed paths for the glyph check, nil to ask git.
    def initialize(root, timeout: DEFAULT_TIMEOUT, runner: nil, files: nil, base: nil)
      @repo = Repo.new(File.realpath(root))
      @timeout = timeout
      @runner = runner || method(:spawn_command)
      @files = files
      @base = base
      @memo = {}
    end

    def call
      lint = Checks.all.map { |check| run_check(check) }
      Report.new(lint + [ run_tests ])
    end

    private

    def run_check(check)
      return result(check.id, 'not_applicable', 'no matching stack source or manifest') unless check.detect.call(@repo)

      if check.tool && !@repo.adopted?(check.tool)
        return result(check.id, 'not_applicable', "#{check.tool} is not adopted here (no config, no dependency)")
      end

      gap = check.missing&.call(@repo, method(:capture))
      return result(check.id, 'unavailable', "missing enforcer: #{gap}") if gap
      return native(check) if check.native

      commands = check.commands.respond_to?(:call) ? check.commands.call(@repo) : check.commands
      return result(check.id, 'not_applicable', 'no tool installed or configured to run here') if commands.empty?

      run_commands(check.id, commands, @timeout)
    end

    def native(check)
      findings = check.native.call(@repo, changed: changed)
      return result(check.id, 'passed', 'no findings') if findings.empty?

      result(check.id, 'failed', "#{findings.size} finding(s)", findings: findings.first(MAX_FINDINGS))
    end

    def run_commands(id, commands, timeout, env: nil, mask: nil)
      commands.each do |command|
        outcome = execute(command, timeout, env)
        return result(id, 'timed_out', "exceeded #{timeout}s", command: command) if outcome.timed_out
        next if outcome.success?

        return result(id, 'failed', "exit #{outcome.exit_code}", command: command, findings: findings_of(mask ? mask.call(outcome.output) : outcome.output))
      end
      result(id, 'passed', "ran #{commands.size} command(s)", command: commands.join(' && '))
    end

    # One command is run once per pass however many rows share it.
    # `env` is a lane entry's restricted environment; without it the runner
    # keeps its own default (the fixed lint and manifest commands).
    def execute(command, timeout, env = nil)
      @memo[[ command, timeout, env ]] ||= env ? @runner.call(command, @repo.root, timeout, env) : @runner.call(command, @repo.root, timeout)
    end

    def capture(command) = execute(command, @timeout)

    def run_tests
      commands, source = TestCommands.resolve(@repo, @timeout)
      if commands.empty?
        note = source.include?('info:') ? " (#{TestCommands::BOOT_SKIP_NOTE})" : ''
        return result('tests', 'not_applicable', "no command lane and no test script in a manifest#{note}")
      end

      commands.each do |entry|
        if entry[:missing]
          return result("tests:#{entry[:name]}", 'unavailable', "declared env not set: #{entry[:missing].join(', ')}", command: entry[:run])
        end

        outcome = run_commands("tests:#{entry[:name]}", [ entry[:run] ], entry[:timeout], env: entry[:env], mask: entry[:mask])
        return outcome unless outcome.status == 'passed'
      end
      result('tests', 'passed', "#{commands.size} command(s) from #{source}")
    end

    def changed
      @changed ||= Changed.new(@repo.root, files: @files, base: @base)
    end

    def findings_of(output)
      lines = output.to_s.lines.map(&:strip).reject(&:empty?)
      located = lines.grep(/\A[^\s:]+:\d+(?::\d+)?[: ]/)
      (located.empty? ? lines.last(10) : located).first(MAX_FINDINGS)
    end

    def result(id, status, detail, command: nil, findings: [])
      Result.new(id: id, status: status, detail: detail, command: command, findings: findings)
    end

    def spawn_command(command, root, timeout, env = ENV.to_h)
      ChangeProcess.run(command, env: env, chdir: root, timeout: timeout, grace: 2)
    end
  end

  # The test commands: the CHANGE.md command lane first, else a manifest.
  module TestCommands
    module_function

    def resolve(repo, timeout)
      return [ manifest_entries(repo, timeout), "manifest (#{BOOT_SKIP_NOTE})" ] if boot_up?(repo)

      lane = lane_entries(repo, timeout)
      return [ lane, 'CHANGE.md command lane' ] unless lane.empty?

      manifest = manifest_entries(repo, timeout)
      [ manifest, 'manifest' ]
    end

    BOOT_SKIP_NOTE = 'info: command lane skipped because boot.up is declared; lanes needing boot run in cf:change instead'

    # A hook never runs boot: a lane that needs provisioned services is left to
    # cf:change, and the manifest test command stands in.
    def boot_up?(repo)
      return false unless repo.file?('CHANGE.md')

      ChangeConfig.load(File.join(repo.root, 'CHANGE.md')).boot.up?
    rescue StandardError
      false
    end

    # Command lane entries run on the host, so they get the lane's own guards:
    # only an entry whose definition equals the base branch's (or one a human
    # cleared for this commit) runs, and it runs with the lane's restricted
    # environment. An untrusted or unverifiable entry is dropped, never run.
    def lane_entries(repo, timeout)
      return [] unless repo.file?('CHANGE.md')

      config = ChangeConfig.load(File.join(repo.root, 'CHANGE.md'))
      section = config.lane('command')
      return [] unless config.enabled_lanes.include?('command')

      trust = lane_trust(repo, config)
      file_values = env_file_values(repo, config)
      Array(section['commands']).select { |entry| entry.is_a?(Hash) && entry['run'] && entry['profiles'].nil? }
                                .select { |entry| trust.trusted?("command:#{entry['name']}") }
                                .map { |entry| lane_entry(entry, timeout, file_values, config) }
    rescue StandardError
      []
    end

    # A declared variable that is unset is reported, never dropped: the entry
    # carries `missing` and stage 1 turns it into an `unavailable` result.
    # boot.env_file values, which the lane resolves declared names from. A
    # missing file contributes nothing, so its names read as unset.
    def env_file_values(repo, config)
      config.boot.env_file_entries.each_with_object({}) do |entry, merged|
        path = File.expand_path(entry, repo.root)
        next unless File.file?(path)

        File.readlines(path, chomp: true).each do |line|
          key, value = line.strip.delete_prefix('export ').split('=', 2)
          merged[key.strip] = value.strip.gsub(/\A['"]|['"]\z/, '') if key && value && !key.start_with?('#')
        end
      end
    end

    # The reserved variables the real lane supplies, so scripts that read them run.
    def run_env(config)
      { 'CF_CHANGE_RUN_ID' => "stage1-#{SecureRandom.hex(4)}", 'CF_CHANGE_TARGET_URL' => config.boot.target_url,
        'CF_CHANGE_HEALTH_URL' => config.boot.health_url }
    end

    def lane_entry(entry, timeout, file_values, config)
      base = { name: entry['name'].to_s, run: entry['run'], timeout: entry['timeout_seconds'] || timeout }
      resolved = ChangeEnv.build(declared: Array(entry['env']), env_file_values: file_values, extra: run_env(config))
      base.merge(env: resolved.env, mask: resolved.masker)
    rescue ChangeEnv::MissingVariables => e
      base.merge(missing: e.names)
    end

    def lane_trust(repo, config)
      ChangeTrust.evaluate(root: repo.root, head_sha: repo.git_head, fetch: false,
                           head_definitions: ChangeTrust.step_definitions(config))
    end

    def manifest_entries(repo, timeout)
      entries = []
      entries << entry('rake', 'bundle exec rake test', timeout) if repo.file?('Gemfile') && rake_test?(repo)
      entries << entry('npm', js_runner(repo), timeout) if js_test_script?(repo)
      entries
    end

    def entry(name, run, timeout) = { name: name, run: run, timeout: timeout }
    def rake_test?(repo) = repo.file?('Rakefile') && repo.read('Rakefile').match?(%r{Rake::TestTask|task\s*\(?\s*:test\b|load_tasks|rails/test})
    def js_runner(repo) = repo.file?('pnpm-lock.yaml') ? 'pnpm test' : (repo.file?('yarn.lock') ? 'yarn test' : 'npm test')

    def js_test_script?(repo)
      scripts = JSON.parse(repo.read('package.json'))['scripts']
      scripts.is_a?(Hash) && scripts['test'].to_s.strip != '' && !scripts['test'].to_s.match?(NPM_PLACEHOLDER_TEST)
    rescue JSON::ParserError, TypeError
      false
    end
  end

  # The changed files and added lines for the glyph check. Added lines only, so
  # a glyph already in a touched file does not block; outside git, every file.
  class Changed
    def initialize(root, files: nil, base: nil)
      @root = File.realpath(root)
      @files = files
      @base = base
    end

    # [[path, line_number, text]] for each added line.
    def added_lines
      return files_lines(@files) if @files
      return files_lines(all_files) unless git?

      diff_lines
    end

    private

    # Only a root that is itself a work tree top-level counts: a directory
    # nested inside another repo is scanned as plain files.
    def git?
      top = git('rev-parse', '--show-toplevel')&.strip
      !top.nil? && File.realpath(top) == @root
    end

    def base
      @base ||= %w[origin/main origin/master main master].find { |ref| git('rev-parse', '--verify', '--quiet', ref) }
      @base && git('merge-base', @base, 'HEAD')&.strip
    end

    def diff_lines
      out = base ? git('diff', '-U0', '--no-color', base) : git('diff', '-U0', '--no-color', 'HEAD')
      lines = parse_diff(out.to_s.scrub)
      lines + untracked.flat_map { |rel| files_lines([ rel ]) }
    end

    def untracked = git('ls-files', '--others', '--exclude-standard').to_s.split("\n")

    def parse_diff(text)
      path = nil
      number = 0
      text.each_line.with_object([]) do |line, found|
        if line.start_with?('+++ ')
          path = line.chomp.delete_prefix('+++ ').delete_prefix('b/')
          path = nil if path == '/dev/null'
        elsif (match = line.match(/\A@@ -\S+ \+(\d+)/))
          number = match[1].to_i
        elsif line.start_with?('+') && path
          found << [ path, number, line[1..].chomp ]
          number += 1
        end
      end
    end

    def all_files
      Dir.glob('**/*', File::FNM_DOTMATCH, base: @root).select do |rel|
        File.file?(File.join(@root, rel)) && !rel.start_with?('.git/') && !rel.split('/').include?('node_modules')
      end
    end

    def files_lines(rels)
      rels.flat_map do |rel|
        path = File.join(@root, rel)
        next [] unless File.file?(path) && File.size(path) < 1_000_000

        text = File.read(path)
        next [] if text.include?("\0")

        text.force_encoding(Encoding::UTF_8).scrub.each_line.with_index(1).map { |line, number| [ rel, number, line.chomp ] }
      end
    end

    def git(*args)
      out, status = Open3.capture2e('git', '-C', @root, *args)
      status.success? ? out : nil
    rescue StandardError
      nil
    end
  end

  # The migration table. Each row names its old rule; deleting a rubric waits
  # for its row to exist here.
  module Checks
    module_function

    def all
      [ typescript, javascript, react, rails, ruby, github_actions, js_testing, vite_secret, glyph ]
    end

    # Judged on ESLint's effective rule settings for a real source file, so a
    # rule switched off is not mistaken for one that is on. Without a source file
    # or a readable `--print-config`, the rule name appearing in the config is
    # the fallback.
    def eslint_missing(*needles, hint:)
      lambda do |repo, capture|
        rules = effective_eslint_rules(repo, capture, JS_EXTENSIONS)
        absent = needles.reject { |needle| eslint_rule_on?(repo, rules, needle) }
        absent.empty? ? nil : "eslint config lacks #{absent.join(', ')}; #{hint}"
      end
    end

    def eslint_rule_on?(repo, rules, name)
      return repo.eslint_config.include?(name) if rules.nil?

      eslint_on?(rules[name])
    end

    def eslint_on?(setting)
      severity = setting.is_a?(Array) ? setting.first : setting
      [ 1, 2, 'warn', 'error' ].include?(severity)
    end

    SAMPLE_FILES = 5
    NON_APP_SOURCE = %r{(?:\.config\.|\.test\.|\.spec\.|(?:\A|/)(?:tests?|spec|scripts?)/|\A[^/]+\z)}

    # Effective rules merged across a few application sources (config files,
    # tests and root-level scripts are sampled last), so a config scoped to
    # application files is judged on the files it scopes. A rule counts if it
    # is on for any sampled file. nil when nothing could be read.
    def effective_eslint_rules(repo, capture, extensions)
      files = repo.sources(extensions, limit: 500)
      app, other = files.partition { |rel| !rel.match?(NON_APP_SOURCE) }
      sample = sampled(app, SAMPLE_FILES) + other.first(1)
      merged = sample.filter_map { |file| eslint_rules_for(capture, file) }.each_with_object({}) do |rules, all|
        rules.each { |name, setting| all[name] = setting if !all.key?(name) || eslint_on?(setting) }
      end
      merged.empty? ? nil : merged
    end

    def sampled(files, count)
      return files if files.size <= count

      step = files.size / count.to_f
      Array.new(count) { |index| files[(index * step).floor] }.uniq
    end

    def eslint_rules_for(capture, file)
      shown = capture.call("npx --no-install eslint --print-config #{Shellwords.escape(file)}")
      return nil unless shown.success?

      rules = JSON.parse(shown.output[/\{.*\}/m].to_s)['rules']
      rules.is_a?(Hash) ? rules : nil
    rescue JSON::ParserError
      nil
    end

    TYPE_CHECKED_RULE = '@typescript-eslint/no-floating-promises'

    # tsc runs when it is installed; ESLint runs only where the repo adopted it.
    def typescript
      Check.new(id: 'typescript', detect: ->(repo) { repo.file?('tsconfig.json') },
                commands: lambda do |repo|
                  [ ('npx --no-install tsc --noEmit' if repo.file?('node_modules/.bin/tsc')),
                    (ESLINT if repo.adopted?(:eslint)) ].compact
                end,
                missing: lambda do |repo, capture|
                  strict, error = TsConfig.strict(repo)
                  next error if error
                  next 'tsconfig.json: set compilerOptions.strict to true (directly or through extends)' unless strict == true
                  next nil unless repo.adopted?(:eslint)

                  rules = effective_eslint_rules(repo, capture, TS_EXTENSIONS)
                  type_checked = rules ? eslint_rule_on?(repo, rules, TYPE_CHECKED_RULE) : repo.eslint_config.match?(/recommended-type-checked|recommendedTypeChecked/)
                  next nil if type_checked

                  'eslint config lacks typescript-eslint recommended-type-checked (tseslint.configs.recommendedTypeChecked)'
                end)
    end

    def javascript
      Check.new(id: 'javascript', tool: :eslint, commands: [ ESLINT ],
                detect: ->(repo) { repo.file?('package.json') || !repo.sources(JS_EXTENSIONS, limit: 1).empty? },
                missing: eslint_missing('no-var', 'eqeqeq', 'prefer-const', hint: 'enable the rules no-var, eqeqeq and prefer-const'))
    end

    def react
      Check.new(id: 'react', tool: :eslint, commands: [ ESLINT ], detect: ->(repo) { repo.dep?('react') },
                missing: lambda do |repo, capture|
                  rules = effective_eslint_rules(repo, capture, %w[jsx tsx js ts])
                  if rules
                    hooks = %w[react-hooks/rules-of-hooks react-hooks/exhaustive-deps]
                    next nil if hooks.all? { |name| eslint_rule_on?(repo, rules, name) }
                  else
                    config = repo.eslint_config
                    next nil if config.include?('react-hooks') && (config.include?('exhaustive-deps') || config.match?(/recommended/))
                  end

                  'eslint config lacks eslint-plugin-react-hooks (rules-of-hooks and exhaustive-deps)'
                end)
    end

    def rails
      Check.new(id: 'rails', tool: :rubocop, commands: [ RUBOCOP ], detect: ->(repo) { repo.rails? },
                missing: cops_enabled(%w[Rails/FindBy], hint: 'require rubocop-rails in .rubocop.yml and keep its cops enabled'))
    end

    def ruby
      cops = %w[Metrics/ClassLength Metrics/MethodLength Metrics/ParameterLists]
      Check.new(id: 'ruby', tool: :rubocop, commands: [ RUBOCOP ], detect: ->(repo) { repo.file?('Gemfile') },
                missing: cops_enabled(cops, hint: 'enable these cops in .rubocop.yml (Enabled: true)'))
    end

    # Asks rubocop itself, so inherited and plugin config count.
    def cops_enabled(cops, hint:)
      lambda do |_repo, capture|
        shown = capture.call("bundle exec rubocop --show-cops #{cops.join(',')}")
        parsed = shown.success? ? YAML.safe_load(shown.output) : nil
        off = cops.reject { |cop| parsed.is_a?(Hash) && parsed.dig(cop, 'Enabled') == true }
        off.empty? ? nil : "#{off.join(', ')} not enabled; #{hint}"
      rescue Psych::Exception
        "rubocop --show-cops unreadable; #{hint}"
      end
    end

    def github_actions
      Check.new(id: 'github_actions', detect: ->(repo) { !(repo.glob('.github/workflows/*.yml') + repo.glob('.github/workflows/*.yaml')).empty? },
                missing: lambda do |_repo, _capture|
                  system('which docker > /dev/null 2>&1') ? nil : 'docker (actionlint and zizmor run as containers)'
                end,
                commands: [ "docker run --rm -v \"$PWD\":/repo:ro -w /repo #{ACTIONLINT_IMAGE} -color=false",
                            "docker run --rm -v \"$PWD\":/repo:ro -w /repo #{ZIZMOR_IMAGE} --format plain .github/workflows" ])
    end

    TEST_PLUGINS = {
      'vitest' => %w[eslint-plugin-vitest @vitest/eslint-plugin],
      'jest' => %w[eslint-plugin-jest],
      'cypress' => %w[eslint-plugin-cypress]
    }.freeze

    def js_testing
      Check.new(id: 'js_testing', tool: :eslint, commands: [ ESLINT ], detect: ->(repo) { TEST_PLUGINS.keys.any? { |dep| repo.dep?(dep) } },
                missing: lambda do |repo, _capture|
                  absent = TEST_PLUGINS.select { |dep, names| repo.dep?(dep) && names.none? { |name| repo.eslint_config.include?(name) } }
                  absent.empty? ? nil : "eslint config lacks #{absent.values.map(&:first).join(', ')} (recommended)"
                end)
    end

    VITE_SECRET = /VITE_(?!\w*(?:PUBLIC|PUBLISHABLE|ANON))\w*(SECRET|KEY|TOKEN)/

    def vite_secret
      Check.new(id: 'vite_secret', detect: ->(repo) { !repo.glob('vite.config.*').empty? },
                native: lambda do |repo, **|
                  repo.sources(SOURCE_EXTENSIONS).flat_map do |rel|
                    repo.read(rel).each_line.with_index(1).filter_map do |line, number|
                      "#{rel}:#{number}: #{line.strip[0, 120]} (VITE_ variables ship to the browser)" if line.match?(VITE_SECRET)
                    end
                  end
                end)
    end

    def glyph
      Check.new(id: 'glyph', detect: ->(_repo) { true },
                native: lambda do |_repo, changed:|
                  # The same escape hatch GlyphGuard honors for downstream product copy.
                  next [] if ENV['CF_ALLOW_GLYPH'] == '1'

                  changed.added_lines.filter_map do |path, number, text|
                    next if path.split('/').include?('fixtures') || !text.match?(PlanCheck::GLYPHS)

                    "#{path}:#{number}: slop glyph #{text[PlanCheck::GLYPHS].dump}"
                  end
                end)
    end
  end

  # Entry point used by the gate and tests.
  def self.run(root, **options) = Run.new(root, **options).call
end

if __FILE__ == $PROGRAM_NAME
  report = ReviewStage1.run(ARGV.fetch(0, Dir.pwd))
  puts(report.blocking? ? report.to_text : 'stage 1: all clear')
  exit(report.blocking? ? 1 : 0)
end
