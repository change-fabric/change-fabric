# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'walkthrough_diagram'
require_relative 'walkthrough_clipcheck'

# Element scenes for cf:walkthrough: short element films. One centered idea
# at a time on a plain background, each a `beat`: a statement line in the
# serif display face, a product card rebuilt at real size, a count-up
# number, a line drawn on, or a cursor click. Every beat lands on a frame
# (`land_at`, a t_ms or a word anchor), enters with a fade and a 0.96 to 1.0
# scale-in that ends on exactly that frame, and exits with a fade. All motion
# goes through one helper, CfEase.p (scripts/walkthrough_ease.js), driven by
# the frame number alone.
#
# An element scene has no screen file: the capture builds its page in memory
# from the scene (WalkthroughElement.screen), after word anchors resolve, so
# an anchored beat needs no committed timing. The page's timing is computed
# here in frames, so the runtime does no time arithmetic of its own.
module WalkthroughElement
  KIND = 'element'
  RUNTIME = File.join(__dir__, 'walkthrough_element.js')
  ID_RE = /\A[a-z0-9][a-z0-9-]*\z/
  BEAT_TYPES = %w[statement card number line cursor].freeze
  SPEC_FIELDS = %w[theme beats steps].freeze
  COMMON_FIELDS = %w[id type land_at enter_ms exit_ms exit_at].freeze
  TYPE_FIELDS = {
    'statement' => %w[lines],
    'card' => %w[title subtitle rows badge width],
    'number' => %w[value format label],
    'line' => %w[points projection label],
    'cursor' => %w[rows controls click click_ms]
  }.freeze
  STEP_OPS = { 'count' => 'number', 'draw' => 'line' }.freeze
  STEP_FIELDS = %w[op id t_ms at from to format duration].freeze
  # Resolved anchor times the render writes beside an anchored beat field;
  # never authored.
  RESOLVED = { 'land_at' => 'land_t_ms', 'exit_at' => 'exit_t_ms' }.freeze
  ENTER_MS = 400
  EXIT_MS = 300
  COUNT_MS = 1200
  DRAW_MS = 1200
  CLICK_MS = 400
  # Content caps: past these a beat stops being one idea. The statement cap
  # is an estimate of a 96 px serif line inside the 1080p safe area.
  MAX_BEATS = 12
  STATEMENT_LINES = (1..2)
  STATEMENT_CHARS = 36
  CARD_ROWS = (0..5)
  CARD_WIDTH = (320..1200)
  CARD_DEFAULT_WIDTH = 720
  LINE_POINTS = (2..32)
  CURSOR_ROWS = (2..6)
  CURSOR_CONTROLS = (0..4)
  TEXT_CHARS = 48
  # A beat window that does not fit its scene, or an unresolved anchor at
  # page build. An ArgumentError, so a frames key that cannot be computed
  # yet reads as stale, as for any other screen.
  class TimingError < ArgumentError; end

  module_function

  def element?(scene) = scene.is_a?(Hash) && scene['kind'] == KIND

  def runtime_sha256 = Digest::SHA256.file(RUNTIME).hexdigest

  # frames_key material: a new runtime or easing helper invalidates frames.
  def key_material = { element_runtime: runtime_sha256, ease: Digest::SHA256.file(WalkthroughDiagram::EASE).hexdigest }

  def spec(scene) = scene['element'].is_a?(Hash) ? scene['element'] : {}

  def beats(scene) = Array(spec(scene)['beats']).grep(Hash)

  def steps(scene) = Array(spec(scene)['steps']).grep(Hash)

  # -- validation ------------------------------------------------------------

  # Keys an element scene refuses: it has no screen file, no store, no
  # pointer interactions (a cursor beat draws its own pointer), no images.
  REFUSED = %w[screen store interactions images].freeze

  def errors(scene, board = {})
    el = scene['element']
    return [ 'an element scene needs an element object' ] unless el.is_a?(Hash)

    errs = REFUSED.filter_map { |k| "an element scene takes no #{k} (its page is generated from the element block)" if scene.key?(k) }
    errs << "element has unknown keys: #{(el.keys - SPEC_FIELDS).join(', ')}" unless (el.keys - SPEC_FIELDS).empty?
    errs << "element.theme must be one of #{WalkthroughDiagram::THEMES.join(', ')}" if el.key?('theme') && !WalkthroughDiagram::THEMES.include?(el['theme'])
    list = el['beats']
    return errs << 'element.beats must be a non-empty list of objects' unless list.is_a?(Array) && !list.empty? && list.all?(Hash)

    errs << "element has #{list.size} beats; the cap is #{MAX_BEATS}" if list.size > MAX_BEATS
    ids = list.map { |b| b['id'] }
    ids.reject { |id| id.to_s.match?(ID_RE) }.each { |id| errs << "element beat id #{id.inspect} must match [a-z0-9][a-z0-9-]*" }
    ids.tally.each { |id, n| errs << "element beat id #{id.inspect} is not unique" if n > 1 }
    list.each { |b| errs.concat(beat_errors(b).map { |e| "element beat #{b['id'].inspect}: #{e}" }) }
    errs.concat(steps_errors(el['steps'], list))
    return errs unless errs.empty? && resolved?(scene)

    errs.concat(window_errors(scene, board))
  end

  def beat_errors(beat)
    type = beat['type']
    return [ "type must be one of #{BEAT_TYPES.join(', ')}" ] unless BEAT_TYPES.include?(type)

    errs = (beat.keys - COMMON_FIELDS - TYPE_FIELDS[type] - RESOLVED.values).map { |k| "#{k} is not a field of a #{type} beat" }
    errs.concat(time_errors(beat, 'land_at', required: true))
    errs.concat(time_errors(beat, 'exit_at'))
    %w[enter_ms exit_ms].each { |k| errs << "#{k} must be a non-negative integer" if beat.key?(k) && !(beat[k].is_a?(Integer) && !beat[k].negative?) }
    errs + send(:"#{type}_errors", beat)
  end

  # A beat time: a non-negative integer t_ms, or a word anchor
  # { word, nth, offset_ms } on the scene's own narration.
  def time_errors(beat, key, required: false)
    return required ? [ "#{key} is required (a t_ms or { word, nth, offset_ms })" ] : [] unless beat.key?(key)

    value = beat[key]
    return [] if value.is_a?(Integer) && !value.negative?
    return [ "#{key} must be a non-negative integer t_ms or a word anchor" ] unless value.is_a?(Hash)

    require_relative 'walkthrough_storyboard'
    WalkthroughStoryboard.anchor_shape_errors({ 'at' => value }).map { |e| "#{key}: #{e.sub(/\Aat[ .]/, '')}" }
  end

  def text?(value, max = TEXT_CHARS) = value.is_a?(String) && !value.strip.empty? && value.size <= max

  def statement_errors(beat)
    lines = beat['lines']
    return [ "lines must be #{STATEMENT_LINES.min} or #{STATEMENT_LINES.max} strings" ] unless lines.is_a?(Array) && STATEMENT_LINES.cover?(lines.size)

    lines.reject { |l| text?(l, STATEMENT_CHARS) }.map do |l|
      "statement line #{l.inspect} must be a non-empty string of at most #{STATEMENT_CHARS} characters (split it into another beat)"
    end
  end

  def card_errors(beat)
    errs = []
    errs << "title must be a non-empty string of at most #{TEXT_CHARS} characters" unless text?(beat['title'])
    %w[subtitle badge].each { |k| errs << "#{k} must be a non-empty string of at most #{TEXT_CHARS} characters" if beat.key?(k) && !text?(beat[k]) }
    errs << "width must be an integer in #{CARD_WIDTH.min}..#{CARD_WIDTH.max}" if beat.key?('width') && !(beat['width'].is_a?(Integer) && CARD_WIDTH.cover?(beat['width']))
    rows = beat['rows'] || []
    return errs << "rows must be a list of at most #{CARD_ROWS.max} { label, value } objects" unless rows.is_a?(Array) && CARD_ROWS.cover?(rows.size) && rows.all?(Hash)

    rows.each_with_index do |r, i|
      errs << "rows #{i} must be { label, value } strings" unless r.keys.sort == %w[label value] && text?(r['label']) && text?(r['value'])
    end
    errs
  end

  def number_errors(beat)
    errs = []
    errs << 'value must be a number' unless beat['value'].is_a?(Numeric)
    errs.concat(WalkthroughDiagram.format_errors(beat['format'])) if beat.key?('format')
    errs << "label must be a non-empty string of at most #{TEXT_CHARS} characters" if beat.key?('label') && !text?(beat['label'])
    errs
  end

  def line_errors(beat)
    errs = []
    pts = beat['points']
    errs << "points must be #{LINE_POINTS.min} to #{LINE_POINTS.max} numbers" unless pts.is_a?(Array) && LINE_POINTS.cover?(pts.size) && pts.all?(Numeric)
    if beat.key?('projection')
      proj = beat['projection']
      errs << "projection must be 1 to #{LINE_POINTS.max} numbers" unless proj.is_a?(Array) && (1..LINE_POINTS.max).cover?(proj.size) && proj.all?(Numeric)
    end
    errs << "label must be a non-empty string of at most #{TEXT_CHARS} characters" if beat.key?('label') && !text?(beat['label'])
    errs
  end

  def cursor_errors(beat)
    errs = []
    rows = beat['rows']
    unless rows.is_a?(Array) && CURSOR_ROWS.cover?(rows.size) && rows.all? { |r| text?(r) }
      return [ "rows must be #{CURSOR_ROWS.min} to #{CURSOR_ROWS.max} non-empty strings of at most #{TEXT_CHARS} characters" ]
    end

    errs << "click must be a row number in 1..#{rows.size}" unless beat['click'].is_a?(Integer) && (1..rows.size).cover?(beat['click'])
    errs << 'click_ms must be a non-negative integer' if beat.key?('click_ms') && !(beat['click_ms'].is_a?(Integer) && !beat['click_ms'].negative?)
    controls = beat['controls'] || []
    unless controls.is_a?(Array) && CURSOR_CONTROLS.cover?(controls.size) && controls.all?(Hash)
      return errs << "controls must be a list of at most #{CURSOR_CONTROLS.max} { label, dims } objects"
    end

    controls.each_with_index do |c, i|
      ok = (c.keys - %w[label dims]).empty? && text?(c['label'], 24) && (!c.key?('dims') || [ true, false ].include?(c['dims']))
      errs << "controls #{i} must be { label (at most 24 characters), dims (true or false) }" unless ok
    end
    errs
  end

  def steps_errors(list, beats)
    return [] if list.nil?
    return [ 'element.steps must be a list of objects' ] unless list.is_a?(Array) && list.all?(Hash)

    by_id = beats.to_h { |b| [ b['id'], b ] }
    list.each_with_index.flat_map do |step, i|
      step_errors(step, by_id).map { |e| "element step #{i}: #{e}" }
    end
  end

  def step_errors(step, by_id)
    op = step['op']
    return [ "op #{op.inspect} must be one of #{STEP_OPS.keys.join(', ')}" ] unless STEP_OPS.key?(op)

    errs = (step.keys - STEP_FIELDS).map { |k| "#{k} is not a field of a #{op} step" }
    errs.concat(step_time_errors(step))
    target = by_id[step['id']]
    errs << "#{op} needs id naming a #{STEP_OPS[op]} beat" unless target && target['type'] == STEP_OPS[op]
    errs << 'duration must be a positive integer' if step.key?('duration') && !(step['duration'].is_a?(Integer) && step['duration'].positive?)
    if op == 'count'
      errs.concat(WalkthroughDiagram.count_errors(step))
    else
      %w[from to format].each { |k| errs << "#{k} is only for count" if step.key?(k) }
    end
    errs
  end

  def step_time_errors(step)
    require_relative 'walkthrough_storyboard'
    return WalkthroughStoryboard.anchor_shape_errors(step) if step.key?('at')
    return [] if step['t_ms'].is_a?(Integer) && !step['t_ms'].negative?

    [ 'needs t_ms (a non-negative integer) or at (a word anchor)' ]
  end

  # -- anchors -----------------------------------------------------------

  # Steps that land on a spoken word; the render gives each its t_ms the
  # way it does an interaction op.
  def anchored_steps(scene) = element?(scene) ? steps(scene).select { |s| s.key?('at') } : []

  # [beat, key] pairs whose time is a word anchor.
  def anchored_beats(scene)
    return [] unless element?(scene)

    beats(scene).flat_map { |b| RESOLVED.keys.select { |k| b[k].is_a?(Hash) }.map { |k| [ b, k ] } }
  end

  def anchored?(scene) = anchored_steps(scene).any? || anchored_beats(scene).any?

  def resolved?(scene) = anchored_beats(scene).all? { |b, k| b.key?(RESOLVED[k]) } && anchored_steps(scene).all? { |s| s.key?('t_ms') }

  # Drops every resolved time, back to the authored shape.
  def strip_resolved!(scene)
    anchored_beats(scene).each { |b, k| b.delete(RESOLVED[k]) }
    anchored_steps(scene).each { |s| s.delete('t_ms') }
  end

  # Gives each anchored beat time its resolved ms through the block (which
  # returns [ms, warning or nil]), then checks the windows. Returns the
  # warnings; raises TimingError when a window does not fit the scene.
  def resolve!(scene, board)
    warnings = anchored_beats(scene).filter_map do |beat, key|
      ms, warning = yield(beat[key])
      beat[RESOLVED[key]] = ms
      "element beat #{beat['id'].inspect} #{key} #{warning}" if warning
    end
    errs = window_errors(scene, board)
    raise TimingError, errs.join('; ') unless errs.empty?

    warnings + windows(scene, board)[:warnings]
  end

  # -- timing ------------------------------------------------------------

  def time_ms(beat, key)
    value = beat[key]
    return value if value.is_a?(Integer)

    beat[RESOLVED[key]]
  end

  def fps(board) = PrototypeCapture.board_fps(board || {})

  # Each beat's window in ms: entrance start, landing, exit start and end
  # (nil when the beat holds to the scene's end). The entrance starts
  # enter_ms before the landing, clamped (with a warning naming the beat)
  # to the scene start or the previous beat's explicit exit end; the beat
  # still lands on land_at. An exit starts at exit_at, else at the next
  # beat's entrance start. Returns { windows:, warnings:, errors: }.
  def windows(scene, board = {})
    duration = PrototypeCapture.scene_duration(scene)
    list = beats(scene)
    warnings = []
    errors = []
    floor = 0
    starts = list.map do |b|
      land = time_ms(b, 'land_at')
      start = land - b.fetch('enter_ms', ENTER_MS)
      if start < floor
        warnings << "element beat #{b['id'].inspect}: entrance would start at #{start} ms, before #{floor} ms; clamped to #{floor} ms (it still lands at #{land} ms)"
        start = floor
      end
      errors << "element beat #{b['id'].inspect}: lands at #{land} ms, before the previous beat has exited (#{floor} ms)" if land < floor
      exit_at = time_ms(b, 'exit_at')
      floor = exit_at + b.fetch('exit_ms', EXIT_MS) if exit_at
      [ b, start, land, exit_at ]
    end
    out = starts.each_with_index.map do |(b, start, land, exit_at), i|
      exit_start = exit_at || starts[i + 1]&.at(1)
      exit_end = exit_start && (exit_start + b.fetch('exit_ms', EXIT_MS))
      errors.concat(bound_errors(b, land, exit_at, exit_end, duration, list[i - 1], starts[i - 1]&.at(2), i))
      { 'id' => b['id'], 'enter_ms' => start, 'land_ms' => land, 'exit_start_ms' => exit_start, 'exit_end_ms' => exit_end }
    end
    steps(scene).each_with_index do |s, i|
      errors << "element step #{i}: t_ms #{s['t_ms']} is past the scene's #{duration} ms" if s['t_ms'].is_a?(Integer) && s['t_ms'] >= duration
    end
    { windows: out, warnings: warnings, errors: errors }
  end

  def bound_errors(beat, land, exit_at, exit_end, duration, prev, prev_land, index)
    label = "element beat #{beat['id'].inspect}"
    errs = []
    errs << "#{label}: lands at #{land} ms, before the previous beat #{prev['id'].inspect} (#{prev_land} ms); beats land in order" if index.positive? && land < prev_land
    errs << "#{label}: lands at #{land} ms, past the scene's #{duration} ms" if land >= duration
    errs << "#{label}: exit_at #{exit_at} ms must be after its landing (#{land} ms)" if exit_at && exit_at <= land
    errs << "#{label}: exits until #{exit_end} ms, past the scene's #{duration} ms" if exit_end && exit_end > duration
    errs
  end

  def window_errors(scene, board = {}) = windows(scene, board)[:errors]

  # Advisory clamps for a scene with no unresolved anchor.
  def warnings(scene, board = {})
    return [] unless element?(scene) && scene['element'].is_a?(Hash) && resolved?(scene) && errors_free?(scene)

    windows(scene, board)[:warnings].map { |w| "scene #{scene['id']}: #{w}" }
  end

  def errors_free?(scene)
    el = scene['element']
    Array(el['beats']).all? { |b| b.is_a?(Hash) && beat_errors(b).empty? }
  end

  # -- the page ------------------------------------------------------------

  # The runtime's input: every beat with its window in frames, and every
  # step with its start and length in frames.
  def plan(scene, board = {})
    raise TimingError, "scene #{scene['id']}: element anchors are unresolved (narrate the scene first)" unless resolved?(scene)

    rate = fps(board)
    f = ->(ms) { ms && PrototypeCapture.frame_at(ms, rate) }
    timing = windows(scene, board)
    raise TimingError, "scene #{scene['id']}: #{timing[:errors].join('; ')}" unless timing[:errors].empty?

    by_id = timing[:windows].to_h { |w| [ w['id'], w ] }
    plan_beats = beats(scene).map do |b|
      w = by_id[b['id']]
      b.slice(*(TYPE_FIELDS[b['type']] + %w[id type])).merge(
        'enter_f' => f.(w['enter_ms']), 'land_f' => f.(w['land_ms']), 'exit_f' => f.(w['exit_start_ms']), 'exit_end_f' => f.(w['exit_end_ms'])
      ).merge(b['type'] == 'cursor' ? { 'click_f' => f.(w['land_ms'] + b.fetch('click_ms', CLICK_MS)) } : {})
    end
    plan_steps = steps(scene).map do |s|
      dur = s['duration'] || (s['op'] == 'count' ? COUNT_MS : DRAW_MS)
      s.slice('op', 'id', 'from', 'to', 'format').merge('t_f' => f.(s['t_ms']), 'dur_f' => [ f.(s['t_ms'] + dur) - f.(s['t_ms']), 1 ].max)
    end
    { 'fps' => rate, 'beats' => plan_beats, 'steps' => plan_steps }
  end

  def theme(scene) = spec(scene)['theme'] == 'light' ? :light : :dark

  def frame(board)
    viewport = PrototypeCapture::DEFAULT_VIEWPORT.merge((board || {})['viewport'] || {})
    { 'w' => viewport['w'], 'h' => viewport['h'], 'safe_inset' => WalkthroughClipcheck.inset,
      'type' => WalkthroughClipcheck.tokens['type_scale'], 'font' => WalkthroughClipcheck.tokens['font'] }
  end

  def json(data) = JSON.generate(data).gsub(/[<>&]/) { |c| format('\\u%04x', c.ord) }

  def esc(text) = text.to_s.gsub(/[<>&"]/, '<' => '&lt;', '>' => '&gt;', '&' => '&amp;', '"' => '&quot;')

  # The scene's whole page, built in memory at capture: the palette (the
  # walkthrough's tokens in the scene's theme, dark by default), the plan,
  # the easing helper, and the runtime. Deterministic for a given scene.
  def screen(scene, root: nil, board: {})
    title = esc(scene['title'] || 'Element film')
    colors = WalkthroughDiagram.palette(root, theme(scene))
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <title>#{title}</title>
      <style>#{WalkthroughDiagram.palette_css(colors)}</style>
      </head>
      <body>
      <main id="cf-element-root" aria-label="#{title}"></main>
      <script type="application/json" id="cf-element">#{json(plan(scene, board))}</script>
      <script type="application/json" id="cf-element-frame">#{json(frame(board))}</script>
      #{WalkthroughDiagram.script(File.read(WalkthroughDiagram::EASE))}
      #{WalkthroughDiagram.script(File.read(RUNTIME))}
      </body>
      </html>
    HTML
  end

  # storyboard.md lines: one per beat, then the steps.
  def md(scene)
    out = beats(scene).map do |b|
      land = b['land_at'].is_a?(Hash) ? "at #{b['land_at']['word'].inspect}" : "#{b['land_at']} ms"
      "- Beat `#{b['id']}` (#{b['type']}) lands #{land}: #{summary(b)}"
    end
    out + steps(scene).map { |s| "- Step #{s['op']} `#{s['id']}` #{s.key?('at') ? "at #{s['at']['word'].inspect}" : "at #{s['t_ms']} ms"}" }
  end

  def summary(beat)
    case beat['type']
    when 'statement' then Array(beat['lines']).join(' / ')
    when 'card' then beat['title'].to_s
    when 'number' then [ beat['value'], beat['label'] ].compact.join(' ')
    when 'line' then beat['label'] || "#{Array(beat['points']).size} points"
    else Array(beat['rows']).join(', ')
    end
  end
end
