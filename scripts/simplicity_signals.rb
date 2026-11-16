#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'prism'

# Evidence signals for the cf:simplicity lens. Reads a git range and reports
# hints a reviewer can check: how much the range adds, which files and types it
# introduces, which dependencies it pulls in, Ruby definitions nothing
# references, and abstract bases or mixins with exactly one user. Every signal
# is a hint, never a finding: the unused-method check cannot see dynamic
# dispatch (send, callbacks, DSLs). Uses only the Ruby standard library (Prism
# ships with Ruby 3.4). Every subprocess takes an argument array, and any
# failure nulls that one field and adds a note instead of crashing.
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
        git('diff', '-U0', base, head).each_line.with_object({}) do |line, acc|
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
      'unused_ts' => nil
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
    source.to_s.scan(/^\s*gem\s+['"]([^'"]+)['"]/).flatten.uniq
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

  # Includes in this type's own body; a nested class or module owns its own.
  def included_modules(class_node)
    own_nodes(class_node).filter_map do |node|
      next unless node.is_a?(Prism::CallNode) && node.name == :include && node.receiver.nil?

      node.arguments&.arguments&.map(&:slice)
    end.flatten
  end

  def own_nodes(node, root: true, &block)
    return enum_for(:own_nodes, node, root:) unless block
    return if !root && (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode))

    yield node
    node.compact_child_nodes.each { |child| own_nodes(child, root: false, &block) }
  end

  # Command-line entry: `signals [--base REF] [--head REF] [--repo DIR]`.
  module CLI
    USAGE = 'usage: simplicity_signals.rb signals [--base REF] [--head REF] [--repo DIR]'

    def self.run(argv, out: $stdout, err: $stderr)
      command, *rest = argv
      flags = parse(rest)
      return usage(err) unless command == 'signals' && flags

      repo = flags.fetch('repo', Dir.pwd)
      head = flags.fetch('head', 'HEAD')
      base = flags['base'] || merge_base(repo, head)
      out.puts JSON.pretty_generate(SimplicitySignals.run(repo:, base:, head:))
      0
    rescue ArgumentError => e
      err.puts e.message
      2
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

    def self.parse(args)
      args.each_slice(2).each_with_object({}) do |(key, value), flags|
        return nil unless %w[--base --head --repo].include?(key) && value

        flags[key.delete_prefix('--')] = value
      end
    end
  end
end

exit SimplicitySignals::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
