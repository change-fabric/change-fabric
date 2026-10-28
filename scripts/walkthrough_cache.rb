# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

# Content-addressed cache for walkthrough media. Keys are sha256 hex over a
# canonical JSON (sorted keys, no whitespace) of the inputs, so the same
# inputs in any hash order map to the same file. Writes land in a temp file
# and are renamed into place, so a crash never leaves a half-written entry.
module WalkthroughCache
  GITIGNORE_LINE = '.cache/'

  module_function

  def canonical_json(obj)
    JSON.generate(canonicalize(obj))
  end

  def canonicalize(obj)
    case obj
    when Hash then obj.map { |k, v| [ k.to_s, canonicalize(v) ] }.sort_by(&:first).to_h
    when Array then obj.map { |v| canonicalize(v) }
    when Symbol then obj.to_s
    else obj
    end
  end

  def key(obj)
    Digest::SHA256.hexdigest(canonical_json(obj))
  end

  def path(root, kind, key, ext)
    File.join(root, kind.to_s, "#{key}.#{ext.to_s.delete_prefix('.')}")
  end

  def fetch(root, kind, key, ext)
    final = path(root, kind, key, ext)
    return final if File.exist?(final)

    FileUtils.mkdir_p(File.dirname(final))
    tmp = "#{final}.tmp-#{Process.pid}-#{rand(1 << 32)}"
    begin
      yield tmp
      raise IOError, "cache producer wrote nothing for #{File.basename(final)}" unless File.exist?(tmp)

      File.rename(tmp, final)
    ensure
      FileUtils.rm_f(tmp)
    end
    final
  end

  def ensure_gitignore(walkthrough_dir)
    FileUtils.mkdir_p(walkthrough_dir)
    file = File.join(walkthrough_dir, '.gitignore')
    lines = File.exist?(file) ? File.read(file).lines.map(&:strip) : []
    return file if lines.include?(GITIGNORE_LINE) || lines.include?('.cache')

    existing = File.exist?(file) ? File.read(file) : ''
    existing += "\n" unless existing.empty? || existing.end_with?("\n")
    File.write(file, "#{existing}#{GITIGNORE_LINE}\n")
    file
  end
end
