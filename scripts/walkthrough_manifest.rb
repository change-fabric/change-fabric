# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'change_docker'
require_relative 'prototype_imagegen'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_storyboard'

# manifest.json pins everything a render depends on: the storyboard digest,
# per-scene resolved keys and derived durations, model ids, container image
# pins, icon package pins, the music key, and the frame timeline. The same
# manifest_hash means the same timeline and the same ffmpeg argv.
module WalkthroughManifest
  SCHEMA_VERSION = 1

  module_function

  def music_key(board, total_ms)
    WalkthroughCache.key({ music: board['music'] || {}, total_ms: total_ms })
  end

  # `keys` defaults to recomputing from disk; tests and the renderer may pass
  # them in. `storyboard_sha256` is the digest of storyboard.json's
  # canonical form, so formatting-only edits do not change it.
  def build(board, root, keys: WalkthroughStoryboard.recompute_keys(board, root))
    line = WalkthroughStoryboard.timeline(board)
    scenes = line['scenes'].map do |entry|
      deps = keys.fetch(entry['id'])
      entry.slice('id', 'start_frame', 'frames', 'duration_ms').merge(
        'frames_key' => deps['frames_key'], 'audio_key' => deps['audio_key'], 'asset_keys' => deps['asset_keys']
      )
    end
    manifest = {
      'schema_version' => SCHEMA_VERSION,
      'storyboard_sha256' => WalkthroughCache.key(board),
      'models' => models(board),
      'images' => { 'browserless' => ChangeDocker::BROWSERLESS_IMAGE, 'ffmpeg' => ChangeDocker::FFMPEG_IMAGE,
                    'node' => ChangeDocker::NODE_IMAGE },
      'icons' => { 'phosphor' => pin(ChangeDocker::PHOSPHOR_PKG), 'simple_icons' => pin(ChangeDocker::SIMPLE_ICONS_PKG) },
      'music_key' => music_key(board, line['total_ms']),
      'timeline' => { 'fps' => line['fps'], 'total_frames' => line['total_frames'], 'total_ms' => line['total_ms'] },
      'scenes' => scenes
    }
    manifest.merge('manifest_hash' => manifest_hash(manifest))
  end

  def models(board)
    { 'voice' => board.dig('voice', 'model'), 'voice_id' => board.dig('voice', 'voice_id'),
      'music' => board.dig('music', 'model'), 'image' => PrototypeImagegen::MODEL }
  end

  def pin(pkg) = { 'name' => pkg[:name], 'version' => pkg[:version], 'integrity' => pkg[:integrity] }

  # sha256 of the manifest's canonical form, excluding the hash field itself.
  def manifest_hash(manifest)
    WalkthroughCache.key(manifest.except('manifest_hash'))
  end

  def write(manifest, root)
    path = File.join(root, 'manifest.json')
    File.write(path, "#{JSON.pretty_generate(manifest)}\n")
    path
  end
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV[0] || abort('usage: walkthrough_manifest.rb walkthrough/<slug>/storyboard.json')
  board = WalkthroughStoryboard.validate!(WalkthroughStoryboard.load(path), root: File.dirname(File.expand_path(path)))
  root = File.dirname(File.expand_path(path))
  manifest = WalkthroughManifest.build(board, root)
  WalkthroughManifest.write(manifest, root)
  puts manifest['manifest_hash']
end
