# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'b_roll'
require_relative 'prototype_capture'
require_relative 'prototype_imagegen'
require_relative 'walkthrough_cache'

# storyboard.json (schema_version 1) is the source of truth for a
# walkthrough. This module validates it, derives scene durations (never
# authored), recomputes each scene's content keys, reports stale keys, and
# renders the read-only storyboard.md.
module WalkthroughStoryboard
  class ValidationError < StandardError; end

  SCHEMA_VERSION = 1
  ID_RE = /\A[a-z0-9][a-z0-9-]*\z/
  TRANSITIONS = %w[cut fade].freeze
  FADE_MS = (100..1500)
  CAMERA_ZOOM = (0.5..3.0)
  DEFAULT_TRANSITION = { 'type' => 'cut', 'ms' => 0 }.freeze
  DEFAULT_IMAGE_SIZE = '1024x1024'
  OPS = %w[move click type hover wait].freeze
  PATCH_OPS = %w[set push delete].freeze
  MD_HEADER = 'Generated from storyboard.json; do not edit'
  BROLL_KIND = 'ai-broll'
  SCENE_KINDS = [ nil, 'screen', BROLL_KIND ].freeze
  BROLL_IMAGE_EXTS = %w[.png .jpg .jpeg .webp].freeze
  BROLL_SECONDS = (1..10)
  KEY_KINDS = { 'frames_key' => 'frames', 'audio_key' => 'audio', 'asset_keys' => 'images', 'broll_key' => 'broll' }.freeze

  module_function

  def load(path) = JSON.parse(File.read(path))

  def fps(board) = board['fps'] || PrototypeCapture::FPS

  def scenes(board) = Array(board['scenes']).sort_by { |s| s['order'].to_i }

  # -- validation ----------------------------------------------------------

  # Returns a list of error strings; empty means valid. `root` is the
  # walkthrough directory, used to check that store seeds exist.
  def validate(board, root: nil)
    errors = []
    errors << "schema_version must be #{SCHEMA_VERSION}" unless board['schema_version'] == SCHEMA_VERSION
    errors << 'slug must match [a-z0-9][a-z0-9-]*' unless board['slug'].to_s.match?(ID_RE)
    list = Array(board['scenes'])
    errors << 'scenes must not be empty' if list.empty?
    hyp_ids = Array(board['hypotheses']).map { |h| h['id'] }
    errors.concat(id_and_order_errors(list))
    orders = list.to_h { |s| [ s['id'], s['order'].to_i ] }
    list.each do |scene|
      label = "scene #{scene['id'].inspect}"
      errors.concat(scene_errors(scene, hyp_ids, orders, root).map { |e| "#{label}: #{e}" })
    end
    errors
  end

  def validate!(board, root: nil)
    errors = validate(board, root: root)
    raise ValidationError, errors.join("\n") unless errors.empty?

    board
  end

  def id_and_order_errors(list)
    errors = []
    ids = list.map { |s| s['id'] }
    ids.each { |id| errors << "scene id #{id.inspect} must match [a-z0-9][a-z0-9-]*" unless id.to_s.match?(ID_RE) }
    ids.tally.each { |id, n| errors << "scene id #{id.inspect} is not unique" if n > 1 }
    orders = list.map { |s| s['order'] }
    errors << 'scene order must be integers unique and contiguous from 1' unless orders.all?(Integer) && orders.sort == (1..list.size).to_a
    errors
  end

  def scene_errors(scene, hyp_ids, orders, root)
    errors = []
    errors << 'duration_ms is derived and must not be authored' if scene.key?('duration_ms') || scene['timing'].is_a?(Hash) && scene['timing'].key?('duration_ms')
    errors.concat(transition_errors(scene.dig('timing', 'transition')))
    errors.concat(camera_errors(scene['camera']))
    errors.concat(interaction_errors(Array(scene['interactions'])))
    Array(scene['hypotheses']).each { |h| errors << "hypothesis #{h} is not in the top-level list" unless hyp_ids.include?(h) }
    errors << 'needs at least one requirement or assumption' if Array(scene['requirements']).empty? && Array(scene['assumptions']).empty?
    errors.concat(kind_errors(scene, root))
    errors.concat(store_errors(scene, orders, root)) if scene['store']
    errors
  end

  def broll?(scene) = scene['kind'] == BROLL_KIND

  # A screen scene needs screen.html; an ai-broll scene needs a broll block and
  # carries no screen.
  def kind_errors(scene, root)
    return [ "kind #{scene['kind'].inspect} must be one of screen, #{BROLL_KIND}" ] unless SCENE_KINDS.include?(scene['kind'])
    return broll_errors(scene, root) if broll?(scene)

    scene.dig('screen', 'html').to_s.empty? ? [ 'screen.html is required' ] : []
  end

  def broll_spec(scene)
    { 'model' => BRoll::MODEL, 'fallback' => 'kenburns' }.merge(scene['broll'].is_a?(Hash) ? scene['broll'] : {})
  end

  def broll_errors(scene, root)
    return [ 'broll is required for an ai-broll scene' ] unless scene['broll'].is_a?(Hash)

    spec = broll_spec(scene)
    errors = []
    errors << 'an ai-broll scene must not carry screen.html' if scene.dig('screen', 'html')
    errors.concat(broll_image_errors(spec['source_image'].to_s, root))
    errors << 'broll.prompt is required' if spec['prompt'].to_s.strip.empty?
    unless spec['seconds'].is_a?(Integer) && BROLL_SECONDS.cover?(spec['seconds'])
      errors << "broll.seconds must be an integer in #{BROLL_SECONDS.min}..#{BROLL_SECONDS.max}"
    end
    errors << "broll.model #{spec['model']} is retired; use #{BRoll::MODEL}" if spec['model'].to_s.match?(BRoll::RETIRED_MODEL_RE)
    errors << "broll.fallback must be one of #{BRoll::FALLBACKS.join(', ')}" unless BRoll::FALLBACKS.include?(spec['fallback'])
    errors
  end

  def broll_image_errors(src, root)
    return [ 'broll.source_image is required' ] if src.empty?
    return [ 'broll.source_image must be inside the walkthrough directory' ] if src.start_with?('/') || src.split('/').include?('..')
    return [ 'broll.source_image must be a png, jpg, or webp' ] unless BROLL_IMAGE_EXTS.include?(File.extname(src).downcase)
    return [ "broll.source_image #{src} does not exist" ] if root && !File.file?(File.join(root, src))

    []
  end

  def transition_errors(transition)
    return [] if transition.nil?

    type = transition['type']
    return [ "transition.type #{type.inspect} must be one of #{TRANSITIONS.join(', ')}" ] unless TRANSITIONS.include?(type)
    return [ "fade transition ms must be in #{FADE_MS.min}..#{FADE_MS.max}" ] if type == 'fade' && !FADE_MS.cover?(transition['ms'].to_i)

    []
  end

  # A declared camera zoom is the only way a scene may resize the device
  # frame (the UX lint's device-frame rule); the screen scales the whole frame
  # uniformly, never reshapes it.
  def camera_errors(camera)
    return [] if camera.nil?
    return [ 'camera must be an object' ] unless camera.is_a?(Hash)
    return [ "camera has unknown keys: #{(camera.keys - %w[zoom]).join(', ')}" ] unless (camera.keys - %w[zoom]).empty?

    zoom = camera['zoom']
    zoom.is_a?(Numeric) && CAMERA_ZOOM.cover?(zoom) ? [] : [ "camera.zoom must be a number in #{CAMERA_ZOOM.min}..#{CAMERA_ZOOM.max}" ]
  end

  def interaction_errors(interactions)
    errors = []
    last = -1
    interactions.each_with_index do |op, i|
      errors << "interaction #{i}: op #{op['op'].inspect} must be one of #{OPS.join(', ')}" unless OPS.include?(op['op'])
      errors << "interaction #{i}: target is required for #{op['op']}" if op['op'] != 'wait' && op['target'].to_s.empty?
      t = op['t_ms']
      if !t.is_a?(Integer) || t.negative?
        errors << "interaction #{i}: t_ms must be a non-negative integer"
      elsif t < last
        errors << "interaction #{i}: t_ms must be non-decreasing"
      else
        last = t
      end
    end
    errors
  end

  def store_errors(scene, orders, root)
    store = scene['store']
    return [ 'store must be an object' ] unless store.is_a?(Hash)

    errors = []
    if (seed = store['seed'])
      errors << "store.seed #{seed} must be under data/" unless seed.start_with?('data/') && !seed.include?('..')
      errors << "store.seed #{seed} does not exist" if root && !File.file?(File.join(root, seed))
    end
    if (from = store['from_scene'])
      if !orders.key?(from)
        errors << "store.from_scene #{from} is not a scene"
      elsif orders[from] >= scene['order'].to_i
        errors << "store.from_scene #{from} must be an earlier scene"
      end
    end
    Array(store['patch']).each_with_index do |op, i|
      errors << "store.patch #{i}: op must be one of #{PATCH_OPS.join(', ')}" unless PATCH_OPS.include?(op['op'])
      errors << "store.patch #{i}: path is required" if op['path'].to_s.empty?
    end
    errors << 'store.prng_seed must be an integer' if store.key?('prng_seed') && !store['prng_seed'].is_a?(Integer)
    errors
  end

  # -- durations and timeline ----------------------------------------------

  # duration_ms = max(min_ms, measured_ms + pad_ms), per scene id.
  def derive_durations(board)
    scenes(board).to_h { |s| [ s['id'], PrototypeCapture.scene_duration(s) ] }
  end

  # Scene start offsets in frames. A fade into a scene overlaps the previous
  # scene by its ms; a cut starts at the previous scene's end.
  def timeline(board)
    fps = fps(board)
    durations = derive_durations(board)
    cursor = 0
    entries = scenes(board).each_with_index.map do |scene, i|
      frames = PrototypeCapture.frame_count(durations[scene['id']], fps)
      transition = scene.dig('timing', 'transition') || DEFAULT_TRANSITION
      overlap = i.positive? && transition['type'] == 'fade' ? PrototypeCapture.frame_at(transition['ms'].to_i, fps) : 0
      start = [ cursor - overlap, 0 ].max
      cursor = start + frames
      { 'id' => scene['id'], 'start_frame' => start, 'frames' => frames, 'duration_ms' => durations[scene['id']],
        'transition' => transition }
    end
    { 'fps' => fps, 'total_frames' => cursor, 'total_ms' => (cursor * 1000.0 / fps).round, 'scenes' => entries }
  end

  # -- keys ----------------------------------------------------------------

  def audio_key(board, scene)
    voice = board['voice'] || {}
    WalkthroughCache.key({ text: scene.dig('narration', 'text').to_s, voice_id: voice['voice_id'], model: voice['model'],
                           output_format: voice['output_format'], settings: voice['settings'] || {} })
  end

  def asset_keys(scene, root, final: false)
    Array(scene['images']).map do |img|
      refs = Array(img['refs']).map { |ref| File.join(root, ref) }
      PrototypeImagegen.asset_key(prompt: img['prompt'].to_s, size: img['size'] || DEFAULT_IMAGE_SIZE,
                                  quality: final ? PrototypeImagegen::QUALITY_FINAL : (img['quality'] || PrototypeImagegen::QUALITY_DRAFT), refs: refs,
                                  model: img['model'] || PrototypeImagegen::MODEL)
    end
  end

  # Recomputed deps per scene id. frames_key is nil when it cannot be
  # computed yet (a from_scene dependency not captured, or a missing screen).
  def recompute_keys(board, root, final: false)
    memo = {}
    scenes(board).to_h do |scene|
      frames = begin
        PrototypeCapture.prepare(board, scene, root, memo, final: final)[:key]
      rescue ArgumentError, PrototypeCapture::UnsupportedContentError, Errno::ENOENT, TypeError
        nil
      end
      keys = { 'frames_key' => frames, 'audio_key' => audio_key(board, scene), 'asset_keys' => asset_keys(scene, root, final: final) }
      keys.merge!(broll_keys(board, scene, root)) if broll?(scene)
      [ scene['id'], keys ]
    end
  end

  # An ai-broll scene's clip key (which includes the model) and its frames
  # key. Frames come from the cached clip when present, else from the
  # scene's fallback over the source still, so a failed generation is a
  # different (stable) key rather than a stale one.
  def broll_keys(board, scene, root)
    spec = broll_spec(scene)
    args = { source_image: File.join(root, spec['source_image'].to_s), prompt: spec['prompt'].to_s, seconds: spec['seconds'],
             model: spec['model'] }
    clip = BRoll.asset_key(**args)
    mode = BRoll.mode_for(File.join(root, '.cache'), spec['fallback'], **args)
    frames = PrototypeCapture.frame_count(PrototypeCapture.scene_duration(scene), fps(board))
    { 'frames_key' => BRoll.frames_key(mode: mode, source_sha: PrototypeCapture.sha256_file(args[:source_image]),
                                       viewport: board['viewport'] || PrototypeCapture::DEFAULT_VIEWPORT, fps: fps(board),
                                       frames: frames, clip_key: mode == 'generated' ? clip : nil),
      'broll_key' => clip }
  rescue Errno::ENOENT, TypeError
    { 'frames_key' => nil, 'broll_key' => nil }
  end

  # Scenes whose authored deps differ from the recomputed ones, with the
  # asset kinds needing regeneration: [{ 'id' =>, 'kinds' => [...] }].
  def stale(board, root, keys = recompute_keys(board, root))
    scenes(board).filter_map do |scene|
      authored = scene['deps'] || {}
      fresh = keys[scene['id']]
      kinds = KEY_KINDS.filter_map { |field, kind| kind if fresh.key?(field) && (fresh[field].nil? || authored[field] != fresh[field]) }
      kinds.empty? ? nil : { 'id' => scene['id'], 'kinds' => kinds }
    end
  end

  # Rewrites each scene's deps to the recomputed keys (validate --fix).
  def fix_keys(board, root, keys = recompute_keys(board, root))
    board['scenes'].each { |scene| scene['deps'] = keys[scene['id']] }
    board
  end

  # -- storyboard.md -------------------------------------------------------

  def render_md(board)
    durations = derive_durations(board)
    out = [ "<!-- #{MD_HEADER} -->", '', "# #{board['title']}", '' ]
    unless Array(board['hypotheses']).empty?
      out << '## Hypotheses' << ''
      board['hypotheses'].each { |h| out << "- #{h['id']} (#{h['dimension']}): #{h['text']}" }
      out << ''
    end
    scenes(board).each { |scene| out.concat(scene_md(scene, durations[scene['id']])) }
    "#{out.join("\n").rstrip}\n"
  end

  def broll_md(scene)
    spec = broll_spec(scene)
    [ "- B-roll: #{spec['source_image']}, #{spec['seconds']}s, #{spec['model']}, fallback #{spec['fallback']}",
      "- B-roll prompt: #{spec['prompt']}" ]
  end

  def scene_md(scene, duration)
    out = [ "## #{scene['order']}. #{scene['title']} (`#{scene['id']}`)", '' ]
    out << "- Duration: #{duration} ms"
    out.concat(broll?(scene) ? broll_md(scene) : [ "- Screen: #{scene.dig('screen', 'html')}" ])
    out << "- User goal: #{scene['user_goal']}" if scene['user_goal']
    out << "- Action: #{scene['action']}" if scene['action']
    out << "- Emphasis: #{scene['emphasis']}" if scene['emphasis']
    out << "- Starts from: #{scene.dig('store', 'from_scene')}" if scene.dig('store', 'from_scene')
    out << "- Hypotheses: #{scene['hypotheses'].join(', ')}" unless Array(scene['hypotheses']).empty?
    out << "- Heuristics shown: #{scene['heuristics_shown'].join(', ')}" unless Array(scene['heuristics_shown']).empty?
    Array(scene['requirements']).each { |r| out << "- Requirement: #{r['source']}#{r['anchor']}" }
    Array(scene['assumptions']).each { |a| out << "- Assumption #{a['id']}: #{a['text']}" }
    out << '' << "> #{scene.dig('narration', 'text')}" if scene.dig('narration', 'text')
    out << ''
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = 'usage: walkthrough_storyboard.rb validate <json> [--fix] | render-md <json> | stale <json>'
  cmd, path = ARGV
  abort(usage) unless cmd && path

  board = WalkthroughStoryboard.load(path)
  root = File.dirname(File.expand_path(path))
  case cmd
  when 'validate'
    errors = WalkthroughStoryboard.validate(board, root: root)
    unless errors.empty?
      warn errors.join("\n")
      exit 1
    end
    if ARGV.include?('--fix')
      WalkthroughStoryboard.fix_keys(board, root)
      File.write(path, "#{JSON.pretty_generate(board)}\n")
      puts 'valid; deps rewritten'
    else
      stale = WalkthroughStoryboard.stale(board, root)
      stale.each { |s| warn "stale #{s['id']}: #{s['kinds'].join(', ')}" }
      puts stale.empty? ? 'valid' : 'valid; stale keys reported (run with --fix to rewrite)'
    end
  when 'render-md'
    WalkthroughStoryboard.validate!(board, root: root)
    out = File.join(root, 'storyboard.md')
    File.write(out, WalkthroughStoryboard.render_md(board))
    puts out
  when 'stale'
    stale = WalkthroughStoryboard.stale(board, root)
    stale.each { |s| puts "#{s['id']}: #{s['kinds'].join(', ')}" }
    puts 'nothing stale' if stale.empty?
  else
    abort(usage)
  end
end
