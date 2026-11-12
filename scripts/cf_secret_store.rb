# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative 'cf_provider_registry'

# Owns ~/.claude/cf/secrets: one 0700 directory per project slug, one hidden
# 0600 file per provider key, and a value-free meta.json beside them (identity,
# realpath, enrolled providers with timestamps, confirmed inherits, deferrals).
# The root comes from ENV['HOME'] at call time so tests inject a temp HOME.
module CfSecretStore
  DIR_MODE = 0o700
  FILE_MODE = 0o600

  module_function

  def root(home = ENV.fetch('HOME', Dir.home)) = File.join(home, '.claude', 'cf', 'secrets')

  def dir(slug) = File.join(root, slug.to_s)

  def key_path(slug, provider) = File.join(dir(slug), CfProviderRegistry.fetch(provider).key_file)

  def meta_path(slug) = File.join(dir(slug), 'meta.json')

  def write_key(slug, provider, value)
    raise ArgumentError, 'empty key' if value.to_s.strip.empty?

    ensure_dir(slug)
    path = key_path(slug, provider)
    atomic_write(path, value.to_s.strip)
    update_meta(slug) do |m|
      (m['enrolled'] ||= {})[provider.to_s] = { 'at' => Time.now.utc.iso8601 }
    end
    path
  end

  def key?(slug, provider) = File.file?(key_path(slug, provider))

  # Only resolution calls this. The value is never logged or written elsewhere.
  def read_key(slug, provider)
    path = key_path(slug, provider)
    File.file?(path) ? File.read(path).strip : nil
  end

  def remove_key(slug, provider)
    FileUtils.rm_f(key_path(slug, provider))
    update_meta(slug) { |m| m['enrolled']&.delete(provider.to_s) } if File.directory?(dir(slug))
  end

  def meta(slug)
    path = meta_path(slug)
    data = File.file?(path) ? JSON.parse(File.read(path)) : {}
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError, SystemCallError
    {}
  end

  # Yields the meta hash for in-place edits and writes it back. Callers record
  # ids, paths, and timestamps only, never key material.
  def update_meta(slug)
    ensure_dir(slug)
    data = meta(slug)
    yield data
    atomic_write(meta_path(slug), "#{JSON.pretty_generate(data)}\n")
    data
  end

  # Seeds identity fields so status can name a project without recomputing it.
  def describe(identity)
    update_meta(identity.slug) do |m|
      m['id'] = identity.id
      m['root'] = identity.root
    end
  end

  def slugs
    return [] unless File.directory?(root)

    Dir.children(root).select { |name| File.directory?(File.join(root, name)) }.sort
  end

  def ensure_dir(slug)
    FileUtils.mkdir_p(root, mode: DIR_MODE)
    File.chmod(DIR_MODE, root)
    FileUtils.mkdir_p(dir(slug), mode: DIR_MODE)
    File.chmod(DIR_MODE, dir(slug))
  end

  def atomic_write(path, content)
    tmp = "#{path}.#{SecureRandom.hex(4)}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) { |f| f.write(content) }
    File.chmod(FILE_MODE, tmp)
    File.rename(tmp, path)
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end
end
