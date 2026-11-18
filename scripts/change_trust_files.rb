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

    def read(rel)
      return File.binread(File.join(@git_root, rel)) unless @ref

      out, status = Open3.capture2('git', '-C', @git_root, 'cat-file', 'blob', "#{@ref}:#{rel}", binmode: true)
      status.success? ? out : nil
    end

    private

    def listing
      @listing ||= @ref ? ref_listing : tree_listing
    end

    def ref_listing
      out, status = Open3.capture2('git', '-C', @git_root, 'ls-tree', '-r', '-l', '-z', @ref)
      return {} unless status.success?

      out.split("\0").each_with_object({}) do |line, files|
        meta, rel = line.split("\t", 2)
        _mode, type, _obj, size = meta.split
        files[rel] = size.to_i if type == 'blob'
      end
    end

    def tree_listing
      out, status = Open3.capture2('git', '-C', @git_root, 'ls-files', '-c', '-o', '--exclude-standard', '-z')
      return {} unless status.success?

      out.split("\0").each_with_object({}) do |rel, files|
        full = File.join(@git_root, rel)
        files[rel] = File.size(full) if File.file?(full)
      end
    end
  end

  module_function

  # { 'files' => { rel => sha256 }, 'error' => reason or nil } for one entry.
  # `cwd` is the entry's working directory, relative to the source root.
  def cover(entry, source, cwd: '')
    error = escape_error(Array(entry['trust_paths']))
    return { 'files' => {}, 'error' => error } if error

    rels = (run_files(entry['run'].to_s, source, cwd) + glob_files(Array(entry['trust_paths']), source)).uniq.sort
    error = cap_error(rels, source)
    return { 'files' => {}, 'error' => error } if error

    { 'files' => rels.to_h { |rel| [ rel, file_digest(source, rel) ] }, 'error' => nil }
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

  def tokens(run)
    Shellwords.split(run)
  rescue ArgumentError
    run.split
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
