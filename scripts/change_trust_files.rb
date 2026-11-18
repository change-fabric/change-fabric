# frozen_string_literal: true

require 'digest'
require 'open3'
require 'pathname'
require 'shellwords'

# The repo files a command lane entry runs, folded into its trust digest
# (0.23.0). Editing a script the entry invokes changes what executes on the
# host as surely as editing the `run` string, so it needs the same approval.
#
# Covered: every token of `run` that names a file in the repo (resolved from
# the entry's working directory), plus every file matching the entry's
# `trust_paths:` globs (resolved from the repo root). Each maps to the SHA-256
# of its content. A path that leaves the repo root, or a set over the cap,
# cannot be verified: the result carries an `error` and the step never counts
# as unchanged from the base branch.
module ChangeTrustFiles
  MAX_FILES = 200
  MAX_BYTES = 5 * 1024 * 1024
  GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

  # The files of one tree: the working tree (tracked and untracked, ignored
  # files excluded) or a commit read with git, never checked out.
  class Source
    attr_reader :root

    def self.working_tree(root) = new(root, nil)

    def self.at_ref(root, ref, snapshot_root) = new(root, ref, snapshot_root)

    def initialize(git_root, ref, root = git_root)
      @git_root = git_root
      @ref = ref
      @root = root
    end

    def paths = @paths ||= listing.keys.to_set

    def size(rel) = listing[rel]

    # A symlink reads as its target path, as git stores it, so the working
    # tree and a snapshot hash it the same way.
    def read(rel)
      return tree_read(rel) unless @ref

      out, status = Open3.capture2('git', '-C', @git_root, 'cat-file', 'blob', "#{@ref}:#{rel}", binmode: true)
      status.success? ? out : nil
    end

    # The stored target of a symlink, nil for a regular file. Filled while
    # listing.
    def link_target(rel)
      listing
      @links_found[rel]
    end

    private

    def tree_read(rel)
      full = File.join(@git_root, rel)
      File.symlink?(full) ? File.readlink(full) : File.binread(full)
    end

    def listing
      @links_found ||= {}
      @listing ||= @ref ? ref_listing : tree_listing
    end

    def ref_listing
      out, status = Open3.capture2('git', '-C', @git_root, 'ls-tree', '-r', '-l', '-z', @ref)
      return {} unless status.success?

      out.split("\0").each_with_object({}) do |line, files|
        meta, rel = line.split("\t", 2)
        mode, type, _obj, size = meta.split
        next unless type == 'blob'

        files[rel] = size.to_i
        @links_found[rel] = read(rel).to_s if mode == '120000'
      end
    end

    def tree_listing
      out, status = Open3.capture2('git', '-C', @git_root, 'ls-files', '-c', '-o', '--exclude-standard', '-z')
      return {} unless status.success?

      out.split("\0").each_with_object({}) do |rel, files|
        full = File.join(@git_root, rel)
        if File.symlink?(full)
          @links_found[rel] = File.readlink(full)
          files[rel] = @links_found[rel].bytesize
        elsif File.file?(full)
          files[rel] = File.size(full)
        end
      end
    end
  end

  # A path whose symlinks lead outside the repo.
  class Escape < StandardError; end

  module_function

  # { 'files' => { rel => sha256 }, 'error' => reason or nil } for one entry.
  # `cwd` is the entry's working directory, relative to the source root.
  def cover(entry, source, cwd: '')
    error = escape_error(Array(entry['trust_paths']))
    return { 'files' => {}, 'error' => error } if error

    begin
      rels = (run_files(entry['run'].to_s, source, cwd) + glob_files(Array(entry['trust_paths']), source)).uniq
    rescue Escape => e
      return { 'files' => {}, 'error' => e.message }
    end
    rels, error = follow_links(rels, source)
    error ||= cap_error(rels, source)
    return { 'files' => {}, 'error' => error } if error

    { 'files' => rels.to_h { |rel| [ rel, file_digest(source, rel) ] }, 'error' => nil }
  end

  # Adds the in-repo target of every covered symlink, so editing the file a
  # link points at is a change too. A target outside the repo cannot be
  # verified.
  def follow_links(rels, source)
    queue = rels.dup
    covered = rels.to_set
    until queue.empty?
      rel = queue.shift
      target = link_dest(rel, source)
      next unless target

      (resolve(target, source) - covered.to_a).each do |found|
        covered << found
        queue << found
      end
    end
    [ covered.to_a.sort, nil ]
  rescue Escape => e
    [ [], e.message ]
  end

  # The repo path the symlink at `rel` points to, nil when `rel` is not a
  # link. Raises Escape when the target is outside the repo.
  def link_dest(rel, source)
    text = source.link_target(rel)
    return nil unless text

    target = text.start_with?('/') ? nil : normalize(File.join(File.dirname(rel), text))
    target || raise(Escape, "symlink #{rel} points outside the repo; refused")
  end

  def file_digest(source, rel)
    body = source.read(rel)
    body ? Digest::SHA256.hexdigest(body) : 'unreadable'
  end

  # Every token is tried against the entry's working directory and every
  # directory the command `cd`s or `pushd`s into, so `cd scripts && bash
  # ci.sh` covers scripts/ci.sh. A directory change that is not a literal
  # path cannot be followed, so the entry cannot be verified.
  def run_files(run, source, cwd)
    words = tokens(run)
    bases = [ cwd ] + changed_dirs(words, cwd)
    words.flat_map do |token|
      bases.flat_map do |base|
        path = base.empty? ? token : File.join(base, token)
        refuse_dotdot_after_link(path, source)
        rel = normalize(path)
        next [] unless rel

        rel.match?(/[*?\[]/) ? glob_files([ rel ], source) : resolve(rel, source)
      end
    end.uniq
  end

  # The shell applies `..` after following a symlinked directory, so
  # collapsing it first would name the wrong file. Such a path fails closed.
  def refuse_dotdot_after_link(path, source)
    parts = path.split('/')
    last = parts.rindex('..')
    return unless last

    parts.first(last).each_index do |index|
      prefix = normalize(parts.first(index + 1).join('/'))
      next unless prefix && source.link_target(prefix)

      raise Escape, "#{path} climbs out of symlinked directory #{prefix}, which cannot be followed; refused"
    end
  end

  def changed_dirs(words, cwd)
    words.each_cons(2).filter_map do |verb, dir|
      next unless %w[cd pushd].include?(verb)
      rel = dir.match?(/[$`~*?]/) ? nil : normalize(cwd.empty? ? dir : File.join(cwd, dir))
      raise Escape, "run changes directory to #{dir.inspect}, which cannot be followed; refused" unless rel

      rel
    end
  end

  # The listed path `rel` names once symlinked directories in its prefix are
  # followed, plus those links, so retargeting one is a change too. [] when
  # it names no listed file.
  def resolve(rel, source, depth = 0)
    return [ rel ] if source.paths.include?(rel)
    raise Escape, "symlink loop resolving #{rel}; refused" if depth > 40

    parts = rel.split('/')
    (1...parts.size).each do |count|
      prefix = parts.first(count).join('/')
      target = link_dest(prefix, source)
      next unless target

      found = resolve(File.join(target, *parts.drop(count)), source, depth + 1)
      return found.empty? ? [] : [ prefix, *found ]
    end
    []
  end

  # Each shell word as quoted, and its pieces with operators and quotes
  # split away, so `"a b.sh"`, `bash x.sh; true` and `sh -c "bash x.sh"` all
  # yield the script. Over-matching a token only adds coverage.
  def tokens(run)
    words = begin
      Shellwords.split(run)
    rescue ArgumentError
      [ run ]
    end
    words.flat_map { |word| [ word, *word.split(/[\s;&|<>()`$'"]+/) ] }.reject(&:empty?).uniq
  end

  # A glob whose leading directory is a symlink also matches under the
  # link's in-repo target, and covers the link, since git lists the link and
  # the target's files but never a path through the link.
  def glob_files(globs, source)
    expanded = through_links(globs, source)
    links = expanded.filter_map { |_, link| link }
    links + expanded.flat_map { |glob, _| source.paths.select { |rel| File.fnmatch?(glob, rel, GLOB_FLAGS) } }
  end

  def through_links(globs, source)
    queue = globs.map { |glob| [ glob, nil ] }
    seen = []
    until queue.empty? || seen.size > 200
      glob, link = queue.shift
      seen << [ glob, link ]
      parts = glob.split('/')
      (1...parts.size).each do |count|
        prefix = parts.first(count).join('/')
        break if prefix.match?(/[*?\[{]/)

        target = link_dest(prefix, source)
        next unless target

        queue << [ File.join(target, *parts.drop(count)), prefix ]
        break
      end
    end
    seen
  end

  # A repo-relative path with `.` segments removed, or nil when it is
  # absolute or climbs out of the root.
  def normalize(path)
    return nil if path.empty? || path.start_with?('/') || path.start_with?('-')

    clean = Pathname.new(path).cleanpath.to_s
    clean == '..' || clean.start_with?('../') || clean == '.' ? nil : clean
  end

  def escape_error(globs)
    bad = globs.find { |glob| !glob.is_a?(String) || glob.start_with?('/') || glob.split(%r{[/{,}]}).include?('..') }
    bad.nil? ? nil : "trust_paths entry #{bad.inspect} escapes the repo root; refused"
  end

  def cap_error(rels, source)
    return "covers #{rels.size} files, over the #{MAX_FILES}-file cap; narrow trust_paths" if rels.size > MAX_FILES

    bytes = rels.sum { |rel| source.size(rel).to_i }
    bytes > MAX_BYTES ? "covers #{bytes} bytes, over the #{MAX_BYTES}-byte cap; narrow trust_paths" : nil
  end

  # The covered files whose content differs between two coverings, a file
  # present on one side only included.
  def changed(head, base)
    head ||= {}
    base ||= {}
    (head.keys | base.keys).reject { |rel| head[rel] == base[rel] }.sort
  end
end
