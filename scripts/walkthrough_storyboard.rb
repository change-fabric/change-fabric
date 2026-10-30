# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'b_roll'
require_relative 'design_config'
require_relative 'prototype_capture'
require_relative 'prototype_imagegen'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_live'

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
  OPS = PrototypeCapture::OPS
  PATCH_OPS = %w[set push delete].freeze
  MD_HEADER = 'Generated from storyboard.json; do not edit'
  BROLL_KIND = 'ai-broll'
  SCENE_KINDS = [ nil, 'screen', BROLL_KIND, WalkthroughCompose::KIND, WalkthroughMessage::KIND ].freeze
  BROLL_IMAGE_EXTS = %w[.png .jpg .jpeg .webp].freeze
  BROLL_SECONDS = (1..10)
  KEY_KINDS = { 'frames_key' => 'frames', 'audio_key' => 'audio', 'asset_keys' => 'images', 'broll_key' => 'broll' }.freeze

  VOICE_EQ_PRESETS = { 'warm' => { 'low_shelf_hz' => 150, 'low_shelf_db' => 3, 'cut_hz' => 3500, 'cut_db' => -2.5 } }.freeze
  VOICE_EQ_BANDS = { 'low_shelf' => %w[low_shelf_hz low_shelf_db], 'cut' => %w[cut_hz cut_db] }.freeze

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
    errors.concat(WalkthroughLive.board_errors(board))
    errors.concat(review_errors(board['review']))
    errors.concat(voice_eq_errors(board.dig('voice', 'eq')))
    orders = list.to_h { |s| [ s['id'], s['order'].to_i ] }
    by_id = list.to_h { |s| [ s['id'], s ] }
    list.each do |scene|
      label = "scene #{scene['id'].inspect}"
      errors.concat(scene_errors(scene, hyp_ids, orders, root, board: board, by_id: by_id).map { |e| "#{label}: #{e}" })
    end
    errors
  end

  # The optional narration EQ: a preset name or an object of band pairs
  # (`low_shelf_hz`/`low_shelf_db`, `cut_hz`/`cut_db`), each pair all or nothing.
  def voice_eq_errors(eq)
    return [] if eq.nil?
    return [] if eq.is_a?(String) && VOICE_EQ_PRESETS.key?(eq)
    return [ "voice.eq preset must be one of #{VOICE_EQ_PRESETS.keys.join(', ')}" ] if eq.is_a?(String)
    return [ 'voice.eq must be a preset name or an object' ] unless eq.is_a?(Hash)

    known = VOICE_EQ_BANDS.values.flatten
    errors = (eq.keys - known).map { |k| "voice.eq.#{k} is not a known field (#{known.join(', ')})" }
    errors << 'voice.eq must set at least one band' if eq.empty?
    VOICE_EQ_BANDS.each_value do |hz, db|
      errors << "voice.eq.#{hz} and voice.eq.#{db} must be set together" if eq.key?(hz) != eq.key?(db)
      errors << "voice.eq.#{hz} must be a number from 20 to 20000" if eq.key?(hz) && !(eq[hz].is_a?(Numeric) && eq[hz].between?(20, 20_000))
      errors << "voice.eq.#{db} must be a number from -24 to 24" if eq.key?(db) && !(eq[db].is_a?(Numeric) && eq[db].between?(-24, 24))
    end
    errors
  end

  # The EQ as an object (a preset expanded), or nil when absent or invalid.
  def voice_eq(board)
    eq = board.dig('voice', 'eq')
    eq = VOICE_EQ_PRESETS[eq] if eq.is_a?(String)
    eq.is_a?(Hash) && !eq.empty? && voice_eq_errors(eq).empty? ? eq : nil
  end

  # The review object roast reads: what the artifact is, who it is for, and the
  # outcomes a viewer must be able to state afterward. Optional here (see
  # warnings); when present it must be well formed.
  def review_errors(review)
    return [] if review.nil?
    return [ 'review must be an object' ] unless review.is_a?(Hash)

    errors = []
    kinds = ChangeSchema::VIDEO_REVIEW_KINDS
    errors << "review.kind must be one of #{kinds.join(', ')}" if review.key?('kind') && !kinds.include?(review['kind'])
    errors << 'review.audience must be a non-empty string' if review.key?('audience') && review['audience'].to_s.strip.empty?
    if review.key?('purpose') && !(review['purpose'].is_a?(Array) && !review['purpose'].empty? && review['purpose'].all? { |p| p.is_a?(String) && !p.strip.empty? })
      errors << 'review.purpose must be a non-empty array of strings'
    end
    errors
  end

  # Advisory findings that never fail validation. Roast refuses to run without a
  # review audience and purpose, so their absence is worth saying early.
  def warnings(board)
    return [ 'review is absent: roast refuses to run without an audience and a purpose (add a review object with kind, audience, purpose)' ] unless board.key?('review')

    review = board['review'].is_a?(Hash) ? board['review'] : {}
    %w[audience purpose].reject { |k| review[k] && !Array(review[k]).empty? && !review[k].to_s.strip.empty? }
                        .map { |k| "review.#{k} is missing: roast refuses to run without it" }
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

  def scene_errors(scene, hyp_ids, orders, root, board: {}, by_id: {})
    errors = []
    errors << 'duration_ms is derived and must not be authored' if scene.key?('duration_ms') || scene['timing'].is_a?(Hash) && scene['timing'].key?('duration_ms')
    errors.concat(transition_errors(scene.dig('timing', 'transition')))
    errors.concat(camera_errors(scene['camera']))
    errors.concat(scene_interaction_errors(scene))
    Array(scene['hypotheses']).each { |h| errors << "hypothesis #{h} is not in the top-level list" unless hyp_ids.include?(h) }
    errors << 'needs at least one requirement or assumption' if Array(scene['requirements']).empty? && Array(scene['assumptions']).empty?
    errors.concat(kind_errors(scene, root))
    if WalkthroughMessage.message?(scene) && !live?(scene)
      errors.concat(WalkthroughMessage.errors(scene, { orders: orders, board: board, root: root }))
      errors.concat(store_errors(scene, orders, root)) if scene['store']
      LIVE_ONLY.each { |key| errors << "#{key} needs a live board (a message scene without screen.html)" if scene.key?(key) && !scene[key].nil? }
    elsif live?(scene)
      errors.concat(WalkthroughLive.scene_errors(scene, board, orders, by_id, root: root))
    else
      errors.concat(store_errors(scene, orders, root)) if scene['store']
      LIVE_ONLY.each { |key| errors << "#{key} needs a screen.url (a live scene)" if scene.key?(key) && !scene[key].nil? }
    end
    errors
  end

  LIVE_ONLY = %w[persona session_from_scene wait storage device devices layout].freeze

  # Interactions are a list, or for a live or compose scene a list per
  # device: { "desktop": [...], "phone": [...] }.
  def scene_interaction_errors(scene)
    list = scene['interactions']
    return interaction_errors(Array(list), live: live?(scene)) unless list.is_a?(Hash)
    return [ 'per-device interactions need a live or compose scene' ] unless live?(scene)

    list.flat_map do |device, ops|
      next [ "interactions.#{device} must be a list" ] unless ops.is_a?(Array)

      interaction_errors(ops, live: true).map { |e| "#{device} #{e}" }
    end
  end

  def broll?(scene) = scene['kind'] == BROLL_KIND

  # Captured in real time (a live or compose scene).
  def live?(scene) = WalkthroughLive.realtime?(scene)

  # A screen scene needs screen.html; an ai-broll scene needs a broll block and
  # carries no screen.
  def kind_errors(scene, root)
    return [ "kind #{scene['kind'].inspect} must be one of screen, #{BROLL_KIND}, #{WalkthroughCompose::KIND}, #{WalkthroughMessage::KIND}" ] unless SCENE_KINDS.include?(scene['kind'])
    return broll_errors(scene, root) if broll?(scene)
    return [] if WalkthroughLive.builtin?(scene)

    screen = scene['screen'].is_a?(Hash) ? scene['screen'] : {}
    return [ 'screen takes exactly one of html or url' ] if screen.key?('html') && screen.key?('url')
    return [] if screen.key?('url')

    screen['html'].to_s.empty? ? [ 'screen.html or screen.url is required' ] : []
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

  # Per-op fields: key needs a valid chord, scroll deltas are integers.
  def op_shape_errors(op)
    case op['op']
    when 'key'
      begin
        PrototypeCapture.key_chord(op['keys'])
        []
      rescue ArgumentError => e
        [ e.message ]
      end
    when 'scroll'
      %w[dx dy].filter_map { |k| "scroll #{k} must be an integer (pixels)" if op.key?(k) && !op[k].is_a?(Integer) }
    else []
    end
  end

  def interaction_errors(interactions, live: false)
    errors = WalkthroughLive.interaction_errors(interactions, live: live)
    ops = live ? WalkthroughLive::OPS : OPS
    last = -1
    interactions.each_with_index do |op, i|
      errors << "interaction #{i}: op #{op['op'].inspect} must be one of #{ops.join(', ')}" unless ops.include?(op['op'])
      errors << "interaction #{i}: target is required for #{op['op']}" if !%w[wait key].include?(op['op']) && op['target'].to_s.empty?
      errors.concat(op_shape_errors(op).map { |e| "interaction #{i}: #{e}" })
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
        prepare_frames(board, scene, root, memo, final: final)[:key]
      rescue ArgumentError, PrototypeCapture::UnsupportedContentError, Errno::ENOENT, TypeError
        nil
      end
      keys = { 'frames_key' => frames, 'audio_key' => audio_key(board, scene), 'asset_keys' => asset_keys(scene, root, final: final) }
      keys.merge!(broll_keys(board, scene, root)) if broll?(scene)
      [ scene['id'], keys ]
    end
  end

  # The frames prep for a screen scene: live scenes key by URL, persona,
  # session parent, and steps; prototype scenes by their inlined screen.
  def prepare_frames(board, scene, root, memo = {}, final: false)
    return WalkthroughLive.prepare(board, scene, root, memo) if live?(scene)

    PrototypeCapture.prepare(board, scene, root, memo, final: final)
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

  # -- tokens.css hash ----------------------------------------------------

  # The canonical tokens.css for a walkthrough at `root`: walking up from
  # root, the first directory whose CHANGE.md-configured tokens path (default
  # design/tokens.css) or bare tokens.css exists. The walk stops at the repo
  # root (a directory holding .git or CHANGE.md). nil when none is found.
  def canonical_tokens(root)
    dir = File.expand_path(root)
    loop do
      configured = begin
        DesignConfig.load(dir).tokens
      rescue StandardError
        DesignConfig::DEFAULT_TOKENS
      end
      found = [ configured, 'tokens.css' ].map { |rel| File.join(dir, rel) }.find { |f| File.file?(f) }
      return found if found
      return nil if %w[.git CHANGE.md].any? { |m| File.exist?(File.join(dir, m)) }

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  end

  def tokens_sha256(path) = Digest::SHA256.file(path).hexdigest

  # tokens_css_sha256 is computed, never hand-written. Reports a missing or
  # stale hash against the canonical tokens.css; silent when none exists.
  def tokens_hash_errors(board, tokens_path)
    return [] unless tokens_path && File.file?(tokens_path)

    recorded = board['tokens_css_sha256']
    return [ "tokens_css_sha256 missing; run validate --fix to compute it from #{tokens_path}" ] if recorded.nil?
    return [] if recorded == tokens_sha256(tokens_path)

    [ "tokens_css_sha256 stale against #{tokens_path}; run validate --fix to recompute it" ]
  end

  # Writes tokens_css_sha256 from the canonical tokens.css (validate --fix).
  # Run before fix_keys so frames keys pick up the new hash.
  def fix_tokens_hash(board, tokens_path)
    board['tokens_css_sha256'] = tokens_sha256(tokens_path) if tokens_path && File.file?(tokens_path)
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
    out.concat(broll?(scene) ? broll_md(scene) : [ "- Screen: #{scene.dig('screen', 'html') || scene.dig('screen', 'url')}" ])
    out << "- Persona: #{scene['persona']}" if scene['persona']
    out << "- Session from: #{scene['session_from_scene']}" if scene['session_from_scene']
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
  usage = 'usage: walkthrough_storyboard.rb validate <json> [--fix] [--tokens PATH] | render-md <json> | stale <json>'
  cmd, path = ARGV
  abort(usage) unless cmd && path
  tokens_flag = ARGV.index('--tokens')

  board = WalkthroughStoryboard.load(path)
  root = File.dirname(File.expand_path(path))
  case cmd
  when 'validate'
    tokens = tokens_flag ? ARGV[tokens_flag + 1] : WalkthroughStoryboard.canonical_tokens(root)
    abort("--tokens #{tokens.inspect} is not a file") if tokens_flag && !(tokens && File.file?(tokens))
    fix = ARGV.include?('--fix')
    errors = WalkthroughStoryboard.validate(board, root: root)
    errors += WalkthroughStoryboard.tokens_hash_errors(board, tokens) unless fix
    unless errors.empty?
      warn errors.join("\n")
      exit 1
    end
    WalkthroughStoryboard.warnings(board).each { |w| warn "warning: #{w}" }
    if fix
      WalkthroughStoryboard.fix_tokens_hash(board, tokens)
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
