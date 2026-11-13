# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

# Content-addressed cache for walkthrough media. Keys are sha256 hex over a
# canonical JSON (sorted keys, no whitespace) of the inputs, so the same
# inputs in any hash order map to the same file. Writes land in a temp file
# and are renamed into place, so a crash never leaves a half-written entry.
module WalkthroughCache
  # Everything generated and heavy stays out of version control: the cache
  # (which holds every rendered MP4), the flats folder with its index and
  # overview boards, any MP4 or caption sidecar (the <slug>-draft and
  # <slug>-final deliverables), and any overview PNG. `.cache` without the
  # slash also covers a .cache symlink (CF_WALKTHROUGH_CACHE_ROOT).
  GITIGNORE_LINES = [ '.cache/', '.cache', 'flats/', '*.mp4', '*.vtt', 'overview*.png' ].freeze

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
    existing = File.exist?(file) ? File.read(file) : ''
    have = existing.lines.map(&:strip)
    missing = GITIGNORE_LINES - have
    return file if missing.empty?

    existing += "\n" unless existing.empty? || existing.end_with?("\n")
    File.write(file, "#{existing}#{missing.join("\n")}\n")
    file
  end

  DEFAULT_OUTPUT = 'walkthrough'

  # Where a walkthrough slug lives, relative to the repo root. No target:
  # walkthrough/<slug>, as always. A design target (spec 0.18.0):
  # walkthrough/<target>/<slug>, or <targets.<n>.output>/<slug> when the
  # target sets one. `config` is the target's DesignConfig::Config, or nil.
  def output_dir(slug, config = nil)
    target = config&.target
    return File.join(DEFAULT_OUTPUT, slug) if target.nil? || target.flat

    File.join(target.output || File.join(DEFAULT_OUTPUT, target.name), slug)
  end

  # Resolves and creates the slug dir under `repo_root`, with the generated
  # media ignored in either location.
  def prepare_output(repo_root, slug, target: nil)
    require_relative 'design_config'
    config = target && DesignConfig.load(repo_root).target(target)
    dir = File.join(repo_root, output_dir(slug, config))
    ensure_gitignore(dir)
    dir
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = 'usage: walkthrough_cache.rb output-dir <slug> [--target <name>] [--repo DIR]'
  abort(usage) unless ARGV[0] == 'output-dir' && ARGV[1] && !ARGV[1].start_with?('--')
  target = ARGV.include?('--target') ? ARGV[ARGV.index('--target') + 1] : nil
  repo = ARGV.include?('--repo') ? File.expand_path(ARGV[ARGV.index('--repo') + 1]) : Dir.pwd
  begin
    puts WalkthroughCache.prepare_output(repo, ARGV[1], target: target)
  rescue StandardError => e
    abort("walkthrough_cache: #{e.message}")
  end
end
