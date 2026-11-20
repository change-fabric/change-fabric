# frozen_string_literal: true

require 'digest'

# Digest of the files that change what a heavy command costs: lockfiles,
# Dockerfiles and compose files at any depth, and the boot/lanes blocks of
# CHANGE.md. Shared by the probe (records it per op) and the gate (marks an op
# stale on mismatch).
module ResourceFingerprint
  LOCKFILES = %w[Gemfile.lock package-lock.json pnpm-lock.yaml yarn.lock].freeze
  DOCKER_FILE = /\A(Dockerfile[\w.-]*|(docker-)?compose[\w.-]*\.ya?ml)\z/
  # Generated or vendored trees; a directory with its own .git is another checkout.
  SKIP_DIRS = %w[node_modules vendor tmp dist build coverage .bundle].freeze
  MAX_DEPTH = 4

  module_function

  def compute(root)
    parts = tracked_files(root, 0).sort.map { |rel| "#{rel}:#{Digest::SHA256.file(File.join(root, rel)).hexdigest}" }
    parts << "change:#{Digest::SHA256.hexdigest(change_block(root))}"
    Digest::SHA256.hexdigest(parts.join("\n"))[0, 16]
  end

  # Root-relative paths of the dependency and Docker files under dir.
  def tracked_files(root, depth, rel = '')
    dir = File.join(root, rel)
    Dir.children(dir).flat_map do |name|
      path = File.join(dir, name)
      child = rel.empty? ? name : File.join(rel, name)
      if File.directory?(path) && !File.symlink?(path)
        descend?(name, path, depth) ? tracked_files(root, depth + 1, child) : []
      elsif File.file?(path) && (LOCKFILES.include?(name) || name.match?(DOCKER_FILE))
        [ child ]
      else
        []
      end
    end
  rescue SystemCallError
    []
  end

  def descend?(name, path, depth)
    depth < MAX_DEPTH && !name.start_with?('.') && !SKIP_DIRS.include?(name) && !File.exist?(File.join(path, '.git'))
  end

  # The boot: and lanes: blocks of CHANGE.md, found by indentation.
  def change_block(root)
    path = File.join(root, 'CHANGE.md')
    return '' unless File.file?(path)

    keep = []
    indent = nil
    File.foreach(path) do |line|
      if (m = line.match(/\A(\s*)(boot|lanes):/))
        indent = m[1].length
        keep << line
      elsif indent
        if line.strip.empty? || line[/\A\s*/].length > indent then keep << line
        else indent = nil
        end
      end
    end
    keep.join
  rescue SystemCallError
    ''
  end
end
