# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'

# Keeps a walkthrough dir's .cache bounded and its deliverables safe.
#
# Deliverables: every render copies its MP4 and VTT out of the cache to
# stable paths beside storyboard.json (<slug>-draft.mp4, <slug>-final.mp4),
# written to a temp file in the same dir and renamed, so deleting .cache
# never loses a video.
#
# Location: CF_WALKTHROUGH_CACHE_ROOT moves the cache out of the walkthrough
# dir (out of a synced tree). The dir's .cache becomes a symlink to
# <root>/<slug>-<16 hex of sha256(realpath of the dir)>, so every module that
# joins <dir>/.cache keeps working; ChangeDocker mounts the link's target.
#
# Pruning: keeps what the caller names live (the current render dir, frames
# and stills of scenes still in the board) and every paid or expensive
# output (narration, music, images, b-roll, pronunciation dictionaries,
# icons). Drops superseded render dirs, dead frames and stills, and roast
# responses plus stale temp files older than the retention. It walks with
# lstat, never descends into or deletes through a symlink, and never touches
# a path whose real location is outside the cache.
module WalkthroughHousekeeping
  CACHE_ROOT_ENV = 'CF_WALKTHROUGH_CACHE_ROOT'
  RETENTION_ENV = 'CF_WALKTHROUGH_RETENTION_DAYS'
  WARN_ENV = 'CF_WALKTHROUGH_CACHE_WARN_GB'
  DEFAULT_RETENTION_DAYS = 14
  DEFAULT_WARN_GB = 2.0
  GB = 1024**3
  # Content-keyed outputs that cost money or a long fetch to regenerate.
  KEPT = %w[audio music images broll pronunciation icons].freeze
  # Kept until older than the retention.
  AGED = %w[roasts].freeze

  class Error < StandardError; end

  module_function

  def cache_dir(root) = File.join(File.expand_path(root), '.cache')

  # Stable per dir: the slug for a readable name, the real path for identity.
  def cache_key(root)
    real = File.realpath(File.expand_path(root))
    "#{File.basename(real)}-#{Digest::SHA256.hexdigest(real)[0, 16]}"
  end

  def external_target(root, env = ENV)
    base = env[CACHE_ROOT_ENV].to_s.strip
    base.empty? ? nil : File.join(File.expand_path(base), cache_key(root))
  end

  # Points <root>/.cache at the configured root. Returns notes to print. An
  # in-tree .cache that is a real dir is left in place (never moved or
  # deleted here); the note says how to move it.
  def ensure_location!(root, env = ENV)
    target = external_target(root, env) or return []
    link = cache_dir(root)
    FileUtils.mkdir_p(target)
    real = File.realpath(target)
    if File.symlink?(link)
      return [] if File.realpath(link) == real

      raise Error, "#{link} links to #{File.readlink(link)}, not #{real} (#{CACHE_ROOT_ENV}); fix or remove the link"
    elsif File.exist?(link)
      return [ "warning: #{CACHE_ROOT_ENV} is set but #{link} is a real dir; move its contents to #{real} " \
               'and delete it to take the cache out of this tree' ]
    end
    File.symlink(real, link)
    [ "cache: #{link} -> #{real}" ]
  end

  # The cache's real path when it is safe to manage: a real dir, or a link
  # to the configured root. Anything else is refused.
  def managed_cache(root, env = ENV)
    link = cache_dir(root)
    return nil unless File.exist?(link)
    return File.realpath(link) unless File.symlink?(link)

    target = external_target(root, env)
    unless target && File.directory?(target) && File.realpath(link) == File.realpath(target)
      raise Error, "refusing: #{link} is a symlink not created by #{CACHE_ROOT_ENV}"
    end

    File.realpath(link)
  end

  # -- deliverables ----------------------------------------------------------

  def deliverable_paths(root, slug, final:)
    stem = File.join(File.expand_path(root), "#{slug}-#{final ? 'final' : 'draft'}")
    { mp4: "#{stem}.mp4", vtt: "#{stem}.vtt" }
  end

  # Copies src to dest via a temp file in dest's dir, then renames it, and
  # checks the result by size and sha256. Returns dest.
  def atomic_copy(src, dest)
    tmp = File.join(File.dirname(dest), ".#{File.basename(dest)}.tmp-#{Process.pid}-#{rand(1 << 32)}")
    FileUtils.cp(src, tmp)
    File.rename(tmp, dest)
    verify_copy!(src, dest)
    dest
  ensure
    FileUtils.rm_f(tmp) if tmp
  end

  def verify_copy!(src, dest)
    ok = File.file?(dest) && File.size(dest) == File.size(src) &&
         Digest::SHA256.file(dest).hexdigest == Digest::SHA256.file(src).hexdigest
    raise Error, "deliverable #{dest} does not match #{src}" unless ok
  end

  # Writes the MP4 (and its VTT, when the render has one) to the stable
  # paths. The cached copies stay where the renderer expects them.
  def deliver(root, slug, mp4, final:)
    paths = deliverable_paths(root, slug, final: final)
    atomic_copy(mp4, paths[:mp4])
    vtt = File.join(File.dirname(mp4), 'walkthrough.vtt')
    File.file?(vtt) ? atomic_copy(vtt, paths[:vtt]) : paths.delete(:vtt)
    paths
  end

  # -- sizes -----------------------------------------------------------------

  # Bytes under path, by lstat, never following a link.
  def bytes(path)
    return 0 unless File.exist?(path) || File.symlink?(path)

    total = 0
    Find.find(path) do |p|
      st = File.lstat(p)
      Find.prune if st.symlink? && p != path
      total += st.size if st.file?
    end
    total
  end

  def report(root, env = ENV)
    cache = managed_cache(root, env) or return {}
    Dir.children(cache).sort.each_with_object(Hash.new(0)) do |name, sizes|
      full = File.join(cache, name)
      sizes[File.directory?(full) && !File.symlink?(full) ? name : 'other'] += bytes(full)
    end
  end

  def env_float(key, default, env)
    v = env[key].to_s.strip
    v.empty? ? default : Float(v)
  rescue ArgumentError
    default
  end

  def warn_gb(env = ENV) = env_float(WARN_ENV, DEFAULT_WARN_GB, env)

  def retention_days(env = ENV) = env_float(RETENTION_ENV, DEFAULT_RETENTION_DAYS, env)

  # A warning line when the cache passes the threshold, else nil.
  def size_warning(root, env = ENV)
    cache = managed_cache(root, env) or return nil
    total = bytes(cache)
    limit = warn_gb(env)
    return nil if total <= limit * GB

    "warning: #{cache} holds #{human(total)}, over #{limit} GB (#{WARN_ENV}); run walkthrough_render.rb " \
      "#{root} --prune --dry-run, or set #{CACHE_ROOT_ENV} to keep the cache out of a synced tree"
  rescue Error
    nil
  end

  def human(n)
    units = %w[B KB MB GB TB]
    v = n.to_f
    i = 0
    while v >= 1024 && i < units.size - 1
      v /= 1024
      i += 1
    end
    i.zero? ? "#{n} B" : format('%.1f %s', v, units[i])
  end

  # -- pruning -----------------------------------------------------------------

  Plan = Struct.new(:drop, :refused, keyword_init: true) do
    def bytes = drop.sum { |e| e[:bytes] }
  end

  # keep: { render: [dir names], frames: [keys], stills: [scene ids] }, or a
  # nil entry to keep that whole category (a key that could not be computed).
  def plan(root, keep:, env: ENV, now: Time.now)
    cache = managed_cache(root, env) or return Plan.new(drop: [], refused: [])
    cutoff = now - (retention_days(env) * 86_400)
    drop = []
    refused = []
    Dir.children(cache).sort.each do |category|
      dir = File.join(cache, category)
      next refused << dir if File.symlink?(dir)
      next unless File.directory?(dir)
      next if KEPT.include?(category)

      names = Dir.children(dir).sort
      victims = case category
      when 'render', 'frames', 'stills' then keep[category.to_sym] ? names - keep[category.to_sym] : []
      when *AGED then names.select { |n| File.lstat(File.join(dir, n)).mtime < cutoff }
      else []
      end
      victims += names.select { |n| n.include?('.tmp-') && File.lstat(File.join(dir, n)).mtime < cutoff }
      victims.uniq.each do |name|
        path = File.join(dir, name)
        inside?(cache, path) ? drop << { path: path, category: category, bytes: bytes(path) } : refused << path
      end
    end
    Plan.new(drop: drop, refused: refused)
  end

  # Not a link, and really under the cache.
  def inside?(cache, path)
    return false if File.symlink?(path)

    File.realpath(path).start_with?("#{cache}/")
  rescue Errno::ENOENT
    false
  end

  # Deletes the plan's entries, rechecking each just before removal.
  def apply!(plan, root, env = ENV)
    cache = managed_cache(root, env) or return 0
    plan.drop.sum do |entry|
      next 0 unless inside?(cache, entry[:path])

      FileUtils.rm_rf(entry[:path])
      entry[:bytes]
    end
  end

  def describe(plan, dry_run:)
    verb = dry_run ? 'would drop' : 'dropped'
    lines = plan.drop.map { |e| "#{verb} #{e[:category]} #{File.basename(e[:path])} #{human(e[:bytes])}" }
    lines += plan.refused.map { |p| "refused (symlink or outside the cache): #{p}" }
    lines << "prune: #{verb} #{plan.drop.size} entries, #{human(plan.bytes)} reclaimed#{dry_run ? ' (dry run)' : ''}"
  end
end
