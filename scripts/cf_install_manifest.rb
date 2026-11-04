# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

# Snapshot only known installer outputs. Never recursively delete a directory;
# uninstall removes an entry only if its current bytes/target still match.
class CfInstallManifest
  def initialize(path:, home: Dir.home)
    @path, @home = path, File.realpath(home)
  end

  def record(paths)
    previous = entries
    current = paths.uniq.filter_map { |path| snapshot(path) }
    obsolete = previous.reject { |entry| current.any? { |row| row['path'] == entry['path'] } }
    obsolete.each { |entry| FileUtils.rm_f(entry['path']) if unchanged?(entry) }
    FileUtils.mkdir_p(File.dirname(@path))
    File.write("#{@path}.tmp", JSON.pretty_generate('version' => 1, 'home' => @home, 'entries' => current) + "\n")
    File.rename("#{@path}.tmp", @path)
  end

  def plan
    entries.map { |entry| { 'path' => entry['path'], 'action' => unchanged?(entry) ? 'remove' : 'preserve-modified-or-missing' } }
  end

  def remove
    plan.each { |entry| FileUtils.rm_f(entry['path']) if entry['action'] == 'remove' }
    # Retain the manifest as a record of modified files intentionally preserved.
  end

  private

  def entries
    return [] unless File.file?(@path)

    data = JSON.parse(File.read(@path))
    raise ArgumentError, 'invalid installation manifest' unless data['version'] == 1 && data['home'] == @home && data['entries'].is_a?(Array)
    raise ArgumentError, 'installation manifest escapes home' unless data['entries'].all? { |entry| entry.is_a?(Hash) && entry['path'].is_a?(String) && File.expand_path(entry['path']).start_with?("#{@home}/") }

    data['entries']
  end

  def safe_path?(path)
    return false unless path.is_a?(String)

    expanded = canonical_leaf(path)
    return false unless expanded.start_with?("#{@home}/")

    # Resolve the parent, not the leaf: a managed symlink can point to a repo
    # outside HOME, but replacing a parent directory with a symlink is unsafe.
    parent = File.dirname(expanded)
    resolved = File.realpath(parent)
    resolved == @home || resolved.start_with?("#{@home}/")
  rescue Errno::ENOENT
    false
  end

  def canonical_leaf(path)
    File.join(File.realpath(File.dirname(path)), File.basename(path))
  end

  def snapshot(path)
    return unless safe_path?(path)
    return { 'path' => canonical_leaf(path), 'link' => File.readlink(path) } if File.symlink?(path)
    return unless File.file?(path)

    { 'path' => canonical_leaf(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
  end

  def unchanged?(entry)
    return false unless safe_path?(entry['path'])

    snapshot(entry['path']) == entry
  end
end
