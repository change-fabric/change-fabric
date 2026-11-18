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
      @listing ||= @ref ? ref_listing : tree_listing
    end

    def ref_listing
      out, status = Open3.capture2('git', '-C', @git_root, 'ls-tree', '-r', '-l', '-z', @ref)
      return {} unless status.success?

      @links_found = {}
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

      @links_found = {}
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

  module_function

  # { 'files' => { rel => sha256 }, 'error' => reason or nil } for one entry.
  # `cwd` is the entry's working directory, relative to the source root.
  def cover(entry, source, cwd: '')
    error = escape_error(Array(entry['trust_paths']))
    return { 'files' => {}, 'error' => error } if error

    rels = (run_files(entry['run'].to_s, source, cwd) + glob_files(Array(entry['trust_paths']), source)).uniq
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
      text = source.link_target(rel)
      next unless text

      target = text.start_with?('/') ? nil : normalize(File.join(File.dirname(rel), text))
      return [ [], "symlink #{rel} points outside the repo; refused" ] unless target
      next if covered.include?(target) || !source.paths.include?(target)

      covered << target
      queue << target
    end
    [ covered.to_a.sort, nil ]
  end

  def file_digest(source, rel)
    body = source.read(rel)
    body ? Digest::SHA256.hexdigest(body) : 'unreadable'
  end

  def run_files(run, source, cwd)
    tokens(run).filter_map do |token|
      rel = normalize(cwd.empty? ? token : File.join(cwd, token))
      rel if rel && source.paths.include?(rel)
    end
  end

  # Shell operators and quoting are split away, so `bash x.sh; true` and
  # `sh -c "bash x.sh"` both yield `x.sh`. Over-matching a token only adds
  # coverage.
  def tokens(run)
    words = begin
      Shellwords.split(run)
    rescue ArgumentError
      [ run ]
    end
    words.flat_map { |word| word.split(/[\s;&|<>()`$'"]+/) }.reject(&:empty?)
  end

  def glob_files(globs, source)
    globs.flat_map { |glob| source.paths.select { |rel| File.fnmatch?(glob, rel, GLOB_FLAGS) } }
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
