# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative 'cf_project_identity'
require_relative 'cf_provider_registry'

# Owns ~/.claude/cf/secrets: one 0700 directory per project slug, one hidden
# 0600 file per provider key, and a value-free meta.json beside them (identity,
# realpath, enrolled providers with timestamps, confirmed inherits, deferrals).
# The root comes from ENV['HOME'] at call time so tests inject a temp HOME.
module CfSecretStore
  DIR_MODE = 0o700
  FILE_MODE = 0o600
  # One path segment: a slug can never climb out of the secrets root.
  SLUG_SHAPE = /\A[A-Za-z0-9_-]+\z/
  # A deferral lasts one of these many days; DEFER_DEFAULT_DAYS when unset.
  DEFER_DAYS = [ 1, 7 ].freeze
  DEFER_DEFAULT_DAYS = 7
  # What a legacy boolean or array deferral migrates to: already lapsed, so
  # the next paid run asks again.
  LAPSED = '1970-01-01T00:00:00Z'

  module_function

  def root(home = ENV.fetch('HOME', Dir.home)) = File.join(home, '.claude', 'cf', 'secrets')

  def dir(slug)
    raise ArgumentError, 'invalid slug' unless slug.to_s.match?(SLUG_SHAPE)

    File.join(root, slug.to_s)
  end

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

  # The value-free enrolled entry for provider at a level: at, and optionally
  # expires_at, label and scope. Empty when nothing is recorded.
  def enrollment(slug, provider)
    entry = meta(slug).dig('enrolled', provider.to_s)
    entry.is_a?(Hash) ? entry : {}
  end

  # Merges fields into the enrolled entry, dropping nil values.
  def update_enrollment(slug, provider, fields)
    update_meta(slug) do |m|
      entry = ((m['enrolled'] ||= {})[provider.to_s] ||= {})
      fields.each { |k, v| v.nil? ? entry.delete(k.to_s) : entry[k.to_s] = v }
    end
  end

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

  # Enrollment levels above a project root (an org folder, a home dir), deepest
  # first, that hold a key for provider. Each is [id, slug]. The project's own
  # level is excluded; whether it may be used is the caller's question.
  def inheritable(root, provider)
    ancestors(root).filter_map do |dir|
      id = "dir:#{dir}"
      slug = CfProjectIdentity.slug(id)
      [ id, slug ] if key?(slug, provider)
    end
  end

  def ancestors(root)
    dirs = []
    dir = File.dirname(root.to_s)
    while dir != dirs.last
      dirs << dir
      dir = File.dirname(dir)
    end
    dirs
  end

  # Records a deferral for provider at this level ending `days` from now and
  # returns its end as ISO8601 UTC. Legacy entries migrate in the same write.
  def defer(slug, provider, days: DEFER_DEFAULT_DAYS, now: Time.now)
    raise ArgumentError, "defer days must be one of #{DEFER_DAYS.join(', ')}" unless DEFER_DAYS.include?(days)

    until_at = (now.utc + (days * 86_400)).iso8601
    update_meta(slug) do |m|
      m['deferred'] = deferrals(m)
      m['deferred'][provider.to_s] = { 'deferred_until' => until_at }
    end
    until_at
  end

  def clear_deferral(slug, provider)
    update_meta(slug) do |m|
      next unless m.key?('deferred')

      m['deferred'] = deferrals(m)
      m['deferred'].delete(provider.to_s)
    end
  end

  # provider => { 'deferred_until' => ISO8601 } for a meta hash. A legacy
  # boolean, an array of names, or any shape it cannot read becomes a lapsed
  # deferral, so nothing old stays silent forever.
  def deferrals(meta)
    raw = meta['deferred']
    raw = raw.to_h { |name| [ name.to_s, true ] } if raw.is_a?(Array)
    return {} unless raw.is_a?(Hash)

    raw.to_h do |provider, entry|
      until_at = entry.is_a?(Hash) ? entry['deferred_until'] : nil
      [ provider.to_s, { 'deferred_until' => readable_time(until_at) ? until_at : LAPSED } ]
    end
  end

  # The end of this level's deferral for provider as a UTC Time, or nil when
  # none is recorded. A lapsed one is still returned; see deferral_active?.
  def deferred_until(slug, provider)
    readable_time(deferrals(meta(slug)).dig(provider.to_s, 'deferred_until'))
  end

  def deferral_active?(slug, provider, now: Time.now)
    until_at = deferred_until(slug, provider)
    !until_at.nil? && until_at > now.utc
  end

  def readable_time(text)
    text.is_a?(String) ? Time.iso8601(text).utc : nil
  rescue ArgumentError
    nil
  end

  # Yields [slug, meta] for every project level holding a readable meta.json.
  # Reads meta.json only, never a key file; a missing, unreadable or malformed
  # meta is skipped. Returns an Enumerator without a block.
  def each_meta
    return enum_for(:each_meta) unless block_given?

    slugs.each do |slug|
      next unless slug.match?(SLUG_SHAPE)

      data = meta(slug)
      yield slug, data unless data.empty?
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
