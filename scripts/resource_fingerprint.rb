# frozen_string_literal: true

require 'digest'

# Digest of the files that change what a heavy command costs: lockfiles,
# Dockerfiles, compose files and the boot/lanes blocks of CHANGE.md. Shared by
# the probe (records it per op) and the gate (marks an op stale on mismatch).
# Digest of the files that change what a command costs.
module ResourceFingerprint
  LOCKFILES = %w[Gemfile.lock package-lock.json pnpm-lock.yaml yarn.lock].freeze
  DOCKER_FILES = '{Dockerfile*,docker-compose*.y*ml,compose*.y*ml}'

  module_function

  def compute(root)
    parts = LOCKFILES.map { |f| digest_file(root, f) }
    parts += Dir.glob(File.join(root, DOCKER_FILES)).sort.map { |p| digest_file(root, File.basename(p)) }
    parts << "change:#{Digest::SHA256.hexdigest(change_block(root))}"
    Digest::SHA256.hexdigest(parts.join("\n"))[0, 16]
  end

  def digest_file(root, name)
    path = File.join(root, name)
    "#{name}:#{File.file?(path) ? Digest::SHA256.file(path).hexdigest : '-'}"
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
