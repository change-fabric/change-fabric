# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'walkthrough_housekeeping'

# Versioned walkthrough deliverables, so every playable cut reaches the user
# and none is overwritten. Drafts land beside storyboard.json as
# <slug>-draft-01.mp4, <slug>-draft-02.mp4, and so on (the next free number
# after the highest on disk, so a gap is never refilled); the master is
# <slug>-final.mp4. A sidecar <slug>-deliveries.json records each file:
# number, kind, sha256, scene frames keys, placeholder scenes, and a one-line
# caption diffed against the previous entry. Free and deterministic.
#
# Every deliverable prints one machine-readable line, in its own fenced
# block, that a session sends to the user (or relays from a subagent):
#
#   walkthrough-draft: <absolute path> | <caption>
module WalkthroughDeliverables
  KINDS = %w[silent partial narrated scene final].freeze
  LINE_PREFIX = 'walkthrough-draft:'
  PROVISIONAL = 'provisional timing (pre-narration)'

  module_function

  def sidecar(root, slug) = File.join(File.expand_path(root), "#{slug}-deliveries.json")

  def draft_re(slug) = /\A#{Regexp.escape(slug)}-draft-(\d{2,})\.mp4\z/

  # One past the highest numbered draft on disk or in the sidecar, from 1.
  def next_number(root, slug)
    on_disk = Dir.children(File.expand_path(root)).filter_map { |f| f[draft_re(slug), 1]&.to_i }
    recorded = entries(root, slug).filter_map { |e| e['number'] }
    ([ 0 ] + on_disk + recorded).max + 1
  end

  def label(number) = number ? format('draft-%02d', number) : 'final'

  def stem(root, slug, number) = File.join(File.expand_path(root), "#{slug}-#{label(number)}")

  def entries(root, slug)
    path = sidecar(root, slug)
    return [] unless File.file?(path)

    Array(JSON.parse(File.read(path))['deliveries'])
  rescue JSON::ParserError
    []
  end

  # Copies the render to its versioned path (and its VTT), records the
  # entry, and returns it with :mp4 and :line. scenes is { id => frames_key },
  # placeholders { id => reason }.
  def deliver(root, slug, mp4, kind:, scenes: {}, placeholders: {}, provisional: false)
    raise ArgumentError, "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)

    number = kind == 'final' ? nil : next_number(root, slug)
    base = stem(root, slug, number)
    paths = { mp4: WalkthroughHousekeeping.atomic_copy(mp4, "#{base}.mp4") }
    vtt = File.join(File.dirname(mp4), 'walkthrough.vtt')
    paths[:vtt] = WalkthroughHousekeeping.atomic_copy(vtt, "#{base}.vtt") if File.file?(vtt)
    list = entries(root, slug)
    entry = { 'number' => number, 'kind' => kind, 'file' => File.basename(paths[:mp4]),
              'sha256' => Digest::SHA256.file(paths[:mp4]).hexdigest, 'scenes' => scenes,
              'placeholders' => placeholders, 'provisional' => provisional }
    entry['caption'] = caption(entry, list.last)
    write(root, slug, list + [ entry ])
    paths.merge(entry: entry, line: line(paths[:mp4], entry['caption']))
  end

  def write(root, slug, list)
    path = sidecar(root, slug)
    File.write("#{path}.tmp", "#{JSON.pretty_generate('deliveries' => list)}\n")
    File.rename("#{path}.tmp", path)
  end

  def line(path, caption) = "#{LINE_PREFIX} #{File.expand_path(path)} | #{caption}"

  # The fenced block a session reads: the line alone between fences.
  def fenced(line) = "```\n#{line}\n```"

  # "draft-03: narrated; scenes b and d refilmed; scene e still a
  # placeholder (waiting on PR)". The first entry names its scene count.
  def caption(entry, prev)
    parts = [ "#{label(entry['number'])}: #{entry['kind']}" ]
    parts << PROVISIONAL if entry['provisional']
    parts.concat(changes(entry, prev))
    parts.concat(entry['placeholders'].map do |id, reason|
      still = prev && prev['placeholders'].key?(id) ? 'still ' : ''
      "scene #{id} #{still}a placeholder (#{reason})"
    end)
    parts.join('; ')
  end

  def changes(entry, prev)
    scenes = entry['scenes']
    return [ "first cut, #{scenes.size} #{scenes.size == 1 ? 'scene' : 'scenes'}" ] unless prev

    was = prev['scenes']
    out = []
    added = scenes.keys - was.keys
    refilmed = scenes.keys.select { |id| was.key?(id) && was[id] != scenes[id] }
    filled = (prev['placeholders'].keys - entry['placeholders'].keys) & scenes.keys
    out << "#{scene_list(filled)} filmed" unless filled.empty?
    out << "#{scene_list(refilmed - filled)} refilmed" unless (refilmed - filled).empty?
    out << "#{scene_list(added)} added" unless added.empty?
    removed = was.keys - scenes.keys
    out << "#{scene_list(removed)} removed" unless removed.empty?
    out << 'no picture change' if out.empty?
    out
  end

  def scene_list(ids)
    return "scene #{ids.first}" if ids.size == 1

    "scenes #{ids[0..-2].join(', ')} and #{ids.last}"
  end

  # The newest numbered draft beside the storyboard, or nil.
  def newest_draft(root)
    Dir.glob(File.join(File.expand_path(root), '*-draft-[0-9][0-9]*.mp4'))
       .max_by { |f| [ f[/-draft-(\d+)\.mp4\z/, 1].to_i, File.mtime(f) ] }
  end
end
