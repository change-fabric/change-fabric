#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'prism'
require 'tmpdir'

# Evidence signals for the cf:simplicity lens. Reads a git range and reports
# hints a reviewer can check: how much the range adds, which files and types it
# introduces, which dependencies it pulls in, Ruby definitions nothing
# references, and abstract bases or mixins with exactly one user. Every signal
# is a hint, never a finding: the unused-method check cannot see dynamic
# dispatch (send, callbacks, DSLs). Uses only the Ruby standard library (Prism
# ships with Ruby 3.4). Every subprocess takes an argument array, and any
# failure nulls that one field and adds a note instead of crashing.
#
# TypeScript unused exports come from ts-prune (MIT), run with npx inside a
# pinned node container and never added to package.json. It runs only when
# the range touches .ts or .tsx files and the repo has a tsconfig.json.
module SimplicitySignals
  # Names that frameworks or Ruby itself call implicitly, so zero textual
  # references says nothing about whether they are used.
  ALLOWLIST = %w[
    initialize call to_s to_h to_a to_json inspect perform method_missing respond_to_missing?
    before_validation after_validation before_save after_save before_create after_create
    before_update after_update before_destroy after_destroy after_commit after_initialize
    setup teardown run main
  ].freeze

  ABSTRACT_NAME = /(?:Base|Abstract)\z|\AAbstract/
  LOCKFILES = %w[Gemfile.lock package-lock.json].freeze
  TS_PRUNE_VERSION = '0.10.3'
  TS_PRUNE_IMAGE = 'node:22.18-alpine@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b'
  TS_EXTENSIONS = %w[.ts .tsx].freeze
  DYNAMIC_NOTE = 'unused_ruby is a hint: dynamic dispatch (send, callbacks, DSLs) is not seen'

  # A git range read at two refs inside one repo.
  class Range
    attr_reader :repo, :base, :head, :notes

    def initialize(repo:, base:, head:)
      @repo = repo
      @base = base
      @head = head
      @notes = []
    end

    def git(*args)
      out, err, status = Open3.capture3('git', '-C', repo, *args)
      raise "git #{args.first} failed: #{err.strip}" unless status.success?

      out
    end

    # File content at a ref, or nil when the path does not exist there.
    def show(ref, path)
      out, _err, status = Open3.capture3('git', '-C', repo, 'show', "#{ref}:#{path}")
      status.success? ? out : nil
    end

    def changed_files
      @changed_files ||= git('diff', '--name-only', '--diff-filter=AMR', base, head).lines.map(&:strip)
    end

    # A head path's path at base: its rename source, else itself.
    def base_path(path)
      @renames ||= git('diff', '--name-status', '-M', '--diff-filter=R', base, head).lines.to_h do |row|
        _status, from, to = row.chomp.split("\t")
        [ to, from ]
      end
      @renames.fetch(path, path)
    end

    def ruby_files(paths) = paths.select { |path| path.end_with?('.rb') }

    # Line numbers added at head, per file, from a zero-context diff.
    def added_lines
      @added_lines ||= begin
        current = nil
        git('diff', '-U0', '--src-prefix=a/', '--dst-prefix=b/', base, head).each_line.with_object({}) do |line, acc|
          current = line.chomp.delete_prefix('+++ b/') if line.start_with?('+++ b/')
          next unless (m = line.match(/\A@@ -\S+ \+(\d+)(?:,(\d+))? @@/))

          start = m[1].to_i
          (acc[current] ||= []).concat((start...(start + (m[2] || '1').to_i)).to_a)
        end
      end
    end

    def note(field, error)
      @notes << "#{field} unavailable: #{error.message}"
      nil
    end
  end

  module_function

  def run(repo:, base:, head:)
    range = Range.new(repo:, base: rev(repo, base), head: rev(repo, head))
    lines = safely(range, 'lines') { line_counts(range) }
    report = {
      'range' => "#{range.base[0, 7]}..#{range.head[0, 7]}",
      'lines' => lines,
      'new_files' => safely(range, 'new_files') { new_files(range) },
      'new_types_per_100' => safely(range, 'new_types_per_100') { new_types_per_100(range, lines) },
      'deps' => safely(range, 'deps') { deps(range) },
      'unused_ruby' => safely(range, 'unused_ruby') { unused_ruby(range) },
      'single_impl' => safely(range, 'single_impl') { single_impl(range) },
      'unused_ts' => safely(range, 'unused_ts') { unused_ts(range) }
    }
    report.merge('notes' => [ DYNAMIC_NOTE, *range.notes ])
  end

  def rev(repo, ref)
    out, err, status = Open3.capture3('git', '-C', repo, 'rev-parse', '--verify', "#{ref}^{commit}")
    raise ArgumentError, "unknown ref #{ref}: #{err.strip}" unless status.success?

    out.strip
  end

  def safely(range, field)
    yield
  rescue StandardError => e
    range.note(field, e)
  end

  def line_counts(range)
    range.git('diff', '--numstat', range.base, range.head).each_line.with_object({ 'added' => 0, 'removed' => 0 }) do |row, acc|
      added, removed = row.split("\t")
      acc['added'] += added.to_i
      acc['removed'] += removed.to_i
    end
  end

  def new_files(range)
    range.git('diff', '--name-only', '--diff-filter=A', range.base, range.head).lines.map(&:strip)
  end

  # Classes and modules present at head but not at base, across changed Ruby
  # files, per 100 added lines.
  def new_types_per_100(range, lines)
    added = lines && lines['added']
    return nil if added.nil?

    # Distinct qualified identities across the range, so a namespace
    # reopened in several files counts once.
    files = range.ruby_files(range.changed_files)
    head = files.flat_map { |path| type_names(range.show(range.head, path)) }.uniq
    base = files.flat_map { |path| type_names(range.show(range.base, range.base_path(path))) }.uniq
    count = (head - base).size
    added.zero? ? 0.0 : (count * 100.0 / added).round(2)
  end

  def type_names(source)
    return [] unless source

    each_type(Prism.parse(source).value).map { |_node, name, _crefs| name }
  end

  # Every class and module with its lexically qualified name, so A::Worker
  # and B::Worker stay two types.
  # Yields each class or module with its qualified name and the lexical
  # scopes (crefs) enclosing its declaration, innermost first. The crefs
  # come from the AST nesting, not the name: `class A::B` at top level is
  # declared in the top-level scope, so its superclass is looked up there.
  def each_type(node, crefs = [], &block)
    return enum_for(:each_type, node, crefs) unless block

    if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      path = node.constant_path.slice
      name = path.start_with?('::') || crefs.empty? ? path.delete_prefix('::') : "#{crefs.first}::#{path}"
      yield node, name, crefs
      crefs = [ name ] + crefs
    end
    node.compact_child_nodes.each { |child| each_type(child, crefs, &block) }
  end

  def walk(node, &block)
    return enum_for(:walk, node) unless block

    yield node
    node.compact_child_nodes.each { |child| walk(child, &block) }
  end

  def deps(range)
    {
      'gemfile_added' => gems(range.show(range.head, 'Gemfile')) - gems(range.show(range.base, 'Gemfile')),
      'package_added' => packages(range.show(range.head, 'package.json')) - packages(range.show(range.base, 'package.json')),
      'lockfile_delta' => lock_count(range, range.head) - lock_count(range, range.base)
    }
  end

  def gems(source)
    source.to_s.scan(/^\s*gem(?:\s+|\s*\(\s*)['"]([^'"]+)['"]/).flatten.uniq
  end

  def packages(source)
    return [] unless source

    json = JSON.parse(source)
    (json.fetch('dependencies', {}).keys + json.fetch('devDependencies', {}).keys).uniq
  end

  # Gemfile.lock spec lines (four-space indent, name then version) plus
  # package-lock.json package entries, at one ref.
  def lock_count(range, ref)
    gem_lock = range.show(ref, 'Gemfile.lock').to_s.scan(/^ {4}\S+ \(/).size
    npm_source = range.show(ref, 'package-lock.json')
    npm_lock = npm_source ? JSON.parse(npm_source).fetch('packages', {}).keys.count { |key| !key.empty? } : 0
    gem_lock + npm_lock
  end

  # Methods and constants defined on added lines that no other line in the
  # head tree names, matched on word boundaries.
  def unused_ruby(range)
    added = range.added_lines
    range.ruby_files(range.changed_files).flat_map do |path|
      lines = added.fetch(path, [])
      definitions(range.show(range.head, path)).filter_map do |name, line|
        next unless lines.include?(line) && !ALLOWLIST.include?(name)
        next if referenced_elsewhere?(range, name, path, line)

        { 'name' => name, 'file' => path, 'line' => line }
      end
    end
  end

  def definitions(source)
    return [] unless source

    walk(Prism.parse(source).value).filter_map do |node|
      case node
      when Prism::DefNode then [ node.name.to_s, node.location.start_line ]
      when Prism::ConstantWriteNode then [ node.name.to_s, node.location.start_line ]
      end
    end
  end

  def referenced_elsewhere?(range, name, path, line)
    term = name.sub(/[?!=]\z/, '')
    out, _err, status = Open3.capture3('git', '-C', range.repo, 'grep', '-wnF', '-e', term, range.head)
    return false unless status.success?

    out.each_line.any? { |hit| !hit.start_with?("#{range.head}:#{path}:#{line}:") }
  end

  # Abstract-looking bases with exactly one subclass, and modules included in
  # exactly one class, limited to types the range defines or changes so a
  # review sees only what this change is responsible for.
  def single_impl(range)
    tree = repo_types(range)
    touched = range.ruby_files(range.changed_files).flat_map { |path| type_names(range.show(range.head, path)) }
    bases = tree[:classes].select { |name, info| info[:abstract] && touched.include?(name) }.keys
    mixins = tree[:modules].select { |name| touched.include?(name) }
    single_users(bases, tree[:subclasses]) + single_users(mixins, tree[:includes])
  end

  def single_users(names, users_by_name)
    names.filter_map do |name|
      users = users_by_name.fetch(name, []).uniq
      { 'base' => name, 'impls' => users } if users.size == 1
    end
  end

  def repo_types(range)
    tree = { classes: {}, modules: [], refs: [] }
    range.ruby_files(range.git('ls-tree', '-r', '--name-only', range.head).lines.map(&:strip)).each do |path|
      collect_types(Prism.parse(range.show(range.head, path).to_s).value, tree)
    end
    resolve_refs(tree)
  end

  def collect_types(root, tree)
    each_type(root).each do |node, name, crefs|
      case node
      when Prism::ModuleNode then tree[:modules] << name
      when Prism::ClassNode then record_class(node, name, crefs, tree)
      end
      included_modules(node).each { |mod| tree[:refs] << [ :includes, mod, [ name ] + crefs, name ] }
    end
  end

  # Superclass and include targets are kept as written, with the lexical
  # scopes they were written in, and resolved once every type is known. A
  # superclass is evaluated where the class is declared, an include inside
  # its body.
  def record_class(node, name, crefs, tree)
    tree[:refs] << [ :subclasses, node.superclass.slice, crefs, name ] if node.superclass
    abstract = name.match?(ABSTRACT_NAME) || node.slice.include?('NotImplementedError')
    tree[:classes][name] = { abstract: } unless tree[:classes][name]&.dig(:abstract)
  end

  def resolve_refs(tree)
    known = tree[:classes].keys + tree[:modules]
    tree[:subclasses] = Hash.new { |h, k| h[k] = [] }
    tree[:includes] = Hash.new { |h, k| h[k] = [] }
    tree.delete(:refs).each { |kind, ref, scopes, user| tree[kind][resolve(ref, scopes, known)] << user }
    tree[:includes] = consumers(tree[:includes], tree[:modules])
    tree
  end

  # A module included into another module is consumed by whatever includes
  # that one, so each mixin's users are expanded through module includers.
  # A module that nothing includes stays a user itself.
  def consumers(includes, modules)
    includes.keys.to_h do |mixin|
      seen = {}
      queue = includes[mixin].dup
      users = []
      until queue.empty?
        user = queue.shift
        next if seen[user]

        seen[user] = true
        via = modules.include?(user) ? includes.fetch(user, []) : []
        via.empty? ? users << user : queue.concat(via)
      end
      [ mixin, users ]
    end.then { |h| Hash.new { |hash, k| hash[k] = [] }.merge(h) }
  end

  # Ruby's lexical lookup: each enclosing scope innermost first, then the
  # top level. An unknown target keeps its written name.
  def resolve(ref, scopes, known)
    return ref.delete_prefix('::') if ref.start_with?('::')

    candidates = scopes.map { |scope| "#{scope}::#{ref}" } + [ ref ]
    candidates.find { |c| known.include?(c) } || ref
  end

  # Includes and prepends in this type's own body (both make it a consumer of
  # the mixin); a nested class or module owns its own.
  def included_modules(class_node)
    own_nodes(class_node).filter_map do |node|
      next unless node.is_a?(Prism::CallNode) && %i[include prepend].include?(node.name) && node.receiver.nil?

      node.arguments&.arguments&.map(&:slice)
    end.flatten
  end

  def own_nodes(node, root: true, &block)
    return enum_for(:own_nodes, node, root:) unless block
    return if !root && (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode))

    yield node
    node.compact_child_nodes.each { |child| own_nodes(child, root: false, &block) }
  end

  # Unused TS exports in files the range changed. Nil when the range has no
  # TS; nil with a note when there is no tsconfig.json or the container fails.
  def unused_ts(range)
    changed = range.changed_files.select { |path| path.end_with?(*TS_EXTENSIONS) }
    return nil if changed.empty?
    raise 'no tsconfig.json at the repo root' unless range.show(range.head, 'tsconfig.json')

    Dir.mktmpdir('cf-ts-prune') do |dir|
      snapshot(range, dir)
      parse_ts_prune(ts_prune_output(dir), changed)
    end
  end

  # Extracts the tree at head, so ts-prune sees the reviewed revision rather
  # than whatever the working tree holds.
  def snapshot(range, dir)
    archive = range.git('archive', '--format=tar', range.head)
    _out, err, status = Open3.capture3('tar', '-x', '-C', dir, stdin_data: archive, binmode: true)
    raise "tar failed: #{err.strip}" unless status.success?
  end

  def ts_prune_output(repo)
    out, err, status = Open3.capture3(
      'docker', 'run', '--rm', '-v', "#{File.expand_path(repo)}:/src:ro", '-w', '/src', TS_PRUNE_IMAGE,
      'npx', '--yes', "ts-prune@#{TS_PRUNE_VERSION}", '-p', 'tsconfig.json'
    )
    raise "ts-prune exited #{status.exitstatus}: #{err.strip[0, 200]}" unless status.success?

    out
  rescue SystemCallError => e
    raise "docker unavailable: #{e.message}"
  end

  # ts-prune prints `path:line - name`, tagging exports used only inside their
  # own file with `(used in module)`; those are skipped.
  def parse_ts_prune(output, changed)
    output.each_line.filter_map do |row|
      next if row.include?('(used in module)')
      next unless (m = row.strip.match(/\A(.+?):(\d+) - (\S+)\z/))

      path = m[1].delete_prefix('/src/').delete_prefix('./')
      { 'name' => m[3], 'file' => path, 'line' => m[2].to_i } if changed.include?(path)
    end
  end

  # Measured change between two refs (D3): numstat lines, files deleted,
  # declared dependencies dropped and the lockfile delta. lines_net is deleted
  # minus added, so a rewrite that adds more than it removes is negative.
  # Measured figures only; estimates live in the verdict and are never summed
  # into these.
  def savings(repo:, before:, after:)
    range = Range.new(repo:, base: rev(repo, before), head: rev(repo, after))
    counts = line_counts(range)
    {
      'lines_added' => counts['added'], 'lines_deleted' => counts['removed'],
      'lines_net' => counts['removed'] - counts['added'],
      'files_removed' => range.git('diff', '--name-only', '--diff-filter=D', range.base, range.head).lines.size,
      'deps_removed' => dropped_deps(range),
      'lockfile_removed' => lock_count(range, range.base) - lock_count(range, range.head)
    }
  end

  def dropped_deps(range)
    gone = gems(range.show(range.base, 'Gemfile')) - gems(range.show(range.head, 'Gemfile'))
    gone += packages(range.show(range.base, 'package.json')) - packages(range.show(range.head, 'package.json'))
    gone.size
  end

  # The verdict from accepted simplicity findings (D8, amended): any accepted
  # P0 is rethink, else any accepted P1 is trim, else ship. Findings from other
  # lenses are ignored. A rebuttal with no recorded grounds (a requirement or
  # settled decision, in `grounds`) counts as an accept, matching roast.rb.
  module Verdict
    PREFIX = 'cf:simplicity:'

    module_function

    # Normalized findings from a roast round and its optional response file.
    # Every issue consumes its own response, simplicity or not, so another
    # issue's rebuttal never lands on this one.
    def from_roast(round, response)
      answers = Array(response && response['responses']).dup
      Array(round['issues']).filter_map do |issue|
        reply = take_reply(answers, issue)
        next unless simplicity_issue?(issue)

        rebutted = reply && reply['verdict'] == 'rebut'
        finding(issue, rebutted ? reply['reason'].to_s : nil, reply&.dig('grounds'))
      end
    end

    def location(item) = (item['where'] || item['screen']).to_s

    # The response for an issue: same location, preferring one whose problem
    # text overlaps the issue's, then one with no problem text, then the first.
    def take_reply(answers, issue)
      same = answers.select { |a| location(a) == location(issue) }
      problem = issue['problem'].to_s.downcase
      pick = same.find { |a| overlaps?(a['problem'].to_s.downcase, problem) } ||
             same.find { |a| a['problem'].to_s.strip.empty? } || same.first
      pick && answers.delete_at(answers.index { |a| a.equal?(pick) })
    end

    def overlaps?(left, right) = !left.empty? && (right.include?(left) || left.include?(right))

    # Only the prefix the lens emits marks a simplicity finding: every roast
    # issue carries a saving, so that field says nothing about the lens.
    def simplicity_issue?(issue)
      [ issue['problem'], issue['where'] ].any? { |text| text.to_s.strip.start_with?(PREFIX) }
    end

    # Normalized findings from a drive-lane findings list.
    def from_findings(list)
      Array(list).select { |f| f['lens'].to_s.delete_prefix('cf:') == 'simplicity' }.map do |f|
        finding(f, f['accepted'] == false ? f['rebuttal'].to_s : nil, f['grounds'] || f['requirement'])
      end
    end

    # A rebuttal holds only when it carries explicit grounds: the requirement
    # or settled decision it cites, recorded in a `grounds` field (or, in a
    # findings file, a `requirement` other than none). Free text is never
    # scanned for keywords.
    def finding(issue, rebuttal, grounds)
      cited = grounds.to_s.strip
      grounded = rebuttal && !rebuttal.strip.empty? && !cited.empty? && cited.casecmp('none') != 0
      { 'priority' => issue['priority'], 'saving' => issue['saving'], 'accepted' => !grounded }
    end

    def summarize(findings)
      accepted = findings.select { |f| f['accepted'] }
      rebutted = findings.size - accepted.size
      {
        'verdict' => verdict(accepted), 'accepted' => accepted.size, 'rebutted' => rebutted,
        'precision' => findings.empty? ? nil : (accepted.size.to_f / findings.size).round(2),
        'estimated' => %w[lines files deps].to_h { |k| [ k, accepted.sum { |f| f['saving'].to_h[k].to_i } ] }
      }
    end

    def verdict(accepted)
      priorities = accepted.map { |f| f['priority'] }
      return 'rethink' if priorities.include?('P0')

      priorities.include?('P1') ? 'trim' : 'ship'
    end

    # `dir` holds round-N.json (and round-N.response.json); N defaults to the latest.
    def from_dir(dir, round = nil)
      round ||= Dir.glob(File.join(dir, 'round-*.json')).filter_map { |p| File.basename(p)[/\Around-(\d+)\.json\z/, 1]&.to_i }.max
      raise ArgumentError, "no round-N.json in #{dir}" unless round

      critic = File.join(dir, "round-#{round}.json")
      raise ArgumentError, "missing #{critic}" unless File.file?(critic)

      response = File.join(dir, "round-#{round}.response.json")
      from_roast(JSON.parse(File.read(critic)), File.file?(response) ? JSON.parse(File.read(response)) : nil)
    rescue JSON::ParserError => e
      raise ArgumentError, "unreadable round file: #{e.message}"
    end
  end

  # Command-line entry: `signals`, `verdict` and `savings` subcommands.
  module CLI
    USAGE = <<~TXT.freeze
      usage: simplicity_signals.rb signals [--base REF] [--head REF] [--repo DIR]
             simplicity_signals.rb verdict (--roast-dir DIR [--round N] | --findings FILE)
             simplicity_signals.rb savings --before REF --after REF [--repo DIR]
    TXT
    FLAGS = {
      'signals' => %w[--base --head --repo], 'verdict' => %w[--roast-dir --round --findings],
      'savings' => %w[--before --after --repo]
    }.freeze

    def self.run(argv, out: $stdout, err: $stderr)
      command, *rest = argv
      flags = FLAGS.key?(command) && parse(rest, FLAGS[command])
      return usage(err) unless flags

      out.puts JSON.pretty_generate(send("run_#{command}", flags))
      0
    rescue ArgumentError, JSON::ParserError => e
      err.puts e.message
      2
    end

    def self.run_signals(flags)
      repo = flags.fetch('repo', Dir.pwd)
      head = flags.fetch('head', 'HEAD')
      SimplicitySignals.run(repo:, base: flags['base'] || merge_base(repo, head), head:)
    end

    def self.run_verdict(flags)
      findings =
        if flags['findings'] && !flags['roast-dir']
          Verdict.from_findings(JSON.parse(File.read(flags['findings'])))
        elsif flags['roast-dir'] && !flags['findings']
          Verdict.from_dir(flags['roast-dir'], flags['round']&.to_i)
        else
          raise ArgumentError, USAGE
        end
      Verdict.summarize(findings)
    rescue SystemCallError => e
      raise ArgumentError, e.message
    end

    def self.run_savings(flags)
      raise ArgumentError, USAGE unless flags['before'] && flags['after']

      SimplicitySignals.savings(repo: flags.fetch('repo', Dir.pwd), before: flags['before'], after: flags['after'])
    end

    def self.usage(err)
      err.puts USAGE
      2
    end

    def self.merge_base(repo, head)
      out, err, status = Open3.capture3('git', '-C', repo, 'merge-base', 'origin/main', head)
      raise ArgumentError, "no merge-base with origin/main (pass --base): #{err.strip}" unless status.success?

      out.strip
    end

    def self.parse(args, allowed)
      args.each_slice(2).each_with_object({}) do |(key, value), flags|
        return nil unless allowed.include?(key) && value

        flags[key.delete_prefix('--')] = value
      end
    end
  end
end

exit SimplicitySignals::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
