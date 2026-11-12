# frozen_string_literal: true

# One ordered event timeline per scene and device: the single source of
# truth for when every interaction acts. A storyboard's ops are authored in
# ms; this converts them to frames once (frame_at everywhere a moment lands,
# frame_count for a span), and validation, the frame plan, both capture
# loops and the cursor track all read the result instead of re-deriving it.
#
# An event is { frame, seq, kind, target, payload, op_index }. On one frame
# events run in seq order (SEQ), then in authored order, so what happens
# first inside a frame is data, not the order of if-blocks in a loop.
#
# Loaded by prototype_capture.rb, whose timing helpers (frame_at,
# frame_count, ease, key_chord) it calls.
require_relative 'walkthrough_transition'

module WalkthroughTimeline
  # Part of every frames key of a scene that glides or taps. Bump it when
  # the meaning of an event changes (a new seq order, a new payload field).
  VERSION = 1

  # Same-frame order: scrolls land first so every later aim reads the
  # scrolled page, then the pointer moves, hovers and presses, then input
  # that acts on the page, then a tap's release, and a navigate last.
  SEQ = { 'scroll' => 0, 'glide_step' => 0, 'move_step' => 1, 'hover' => 2, 'press' => 3,
          'type_char' => 4, 'key' => 4, 'click' => 4, 'dblclick' => 4, 'release' => 5, 'navigate' => 6 }.freeze
  KINDS = SEQ.keys.freeze

  # Kinds whose intervals on one target may not overlap: two scrolls of one
  # element fight over its offset, and two presses of one element fight over
  # its pressed look.
  FAMILIES = { 'glide' => 'scroll', 'scroll' => 'scroll', 'press' => 'press' }.freeze
  PLURAL = { 'scroll' => 'scrolls', 'press' => 'presses' }.freeze

  Event = Struct.new(:frame, :seq, :kind, :target, :payload, :op_index, :sub, keyword_init: true) do
    def sort_key = [ frame, seq, op_index, sub ]

    # The event as the capture loops read it: kind and target plus payload.
    def to_js = { 'kind' => kind, 'target' => target }.compact.merge(payload)
  end

  Interval = Struct.new(:target, :from_frame, :to_frame, :kind, :op_index, keyword_init: true) do
    def family = FAMILIES.fetch(kind)

    def overlaps?(other) = from_frame <= other.to_frame && other.from_frame <= to_frame
  end

  # The built timeline of one device's ops over `frames` frames.
  class Timeline
    attr_reader :events, :intervals, :frames, :fps, :late

    def initialize(events:, intervals:, frames:, fps:, late:)
      @events = events.sort_by(&:sort_key)
      @intervals = intervals
      @frames = frames
      @fps = fps
      @late = late
    end

    # One list per frame, each in run order, as the capture loops read it.
    def events_by_frame
      by = Array.new(frames) { [] }
      events.each { |e| by[e.frame] << e.to_js if e.frame < frames }
      by
    end

    def navigate = events.find { |e| e.kind == 'navigate' }

    # The frame the next scene starts on: the navigate tap's release.
    def cut_frame = navigate&.frame

    # The frame the navigate tap's finger landed, so the ripple's age at
    # the cut is cut_frame - press_frame.
    def navigate_press_frame
      nav = navigate or return nil
      events.find { |e| e.kind == 'press' && e.op_index == nav.op_index }&.frame
    end

    # Every way this device's ops conflict, as messages, from frames alone.
    def conflicts = navigate_conflicts + overlap_conflicts + late_conflicts

    private

    # Nothing may act on or after the navigate frame: it would land on the
    # destination page. The navigate tap's own release runs first on that
    # frame by seq, so it is the one exception.
    def navigate_conflicts
      navs = events.select { |e| e.kind == 'navigate' }
      return [] if navs.empty?

      cut = navs.map(&:frame).min
      late = events.reject { |e| navs.any? { |n| n.op_index == e.op_index } || e.frame < cut || e.frame >= frames }
      late.group_by(&:op_index).map do |index, list|
        e = list.min_by(&:sort_key)
        "a navigate tap must be the last input: op #{index} (#{e.kind} #{e.target}) acts at frame #{e.frame}, " \
          "on or after the navigate at frame #{cut}"
      end
    end

    def overlap_conflicts
      intervals.group_by { |i| [ i.family, i.target ] }.flat_map do |(family, target), list|
        list.combination(2).filter_map do |a, b|
          next unless a.overlaps?(b)

          a, b = [ a, b ].sort_by { |i| [ i.from_frame, i.op_index ] }
          "#{PLURAL.fetch(family)} on #{target} overlap: op #{a.op_index} runs frames #{a.from_frame}..#{a.to_frame}, " \
            "op #{b.op_index} starts at frame #{b.from_frame}"
        end
      end
    end

    # A tap must release inside the scene; a release past the last frame
    # would never land, leaving the pressed look stuck.
    def late_conflicts
      late.map do |e|
        "op #{e.op_index} (tap #{e.target}) releases at frame #{e.frame}, past the scene's last frame #{frames - 1}"
      end
    end
  end

  module_function

  # The timeline of one device's ops (each a storyboard op hash) over
  # `frames` frames at `fps`. Events past the last frame are dropped, as a
  # scene that ends mid-type never types the rest; a tap release or a
  # navigate past it is kept in `late` and reported by conflicts.
  def build(ops, fps:, frames:)
    events = []
    intervals = []
    Array(ops).each_with_index do |op, i|
      raise ArgumentError, "unknown interaction op #{op['op']}" unless PrototypeCapture::OPS.include?(op['op'])

      add_op(op, i, fps, events, intervals)
    end
    late = events.select { |e| e.kind == 'release' && e.frame >= frames }
    Timeline.new(events: events, intervals: intervals, frames: frames, fps: fps, late: late)
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def add_op(op, index, fps, events, intervals)
    start = PrototypeCapture.frame_at(op['t_ms'].to_i, fps)
    ev = ->(frame, kind, payload = {}, sub = 0) { events << event(frame, kind, op['target'], payload, index, sub) }
    case op['op']
    when 'move' then add_span(op, index, start, span(op['duration_ms'], fps), events, 'move_step', op['easing'])
    when 'click', 'dblclick', 'hover' then ev.call(start, op['op'])
    when 'type' then add_type(op, index, fps, events)
    when 'key' then ev.call(start, 'key', { 'keys' => PrototypeCapture.key_chord(op['keys']) })
    when 'tap' then add_tap(op, index, start, fps, events, intervals)
    when 'scroll'
      if op['ms']
        n = span(op['ms'], fps)
        add_span(op, index, start, n, events, 'glide_step', op['ease'] || PrototypeCapture::DEFAULT_SCROLL_EASE)
        intervals << Interval.new(target: op['target'], from_frame: start, to_frame: start + n - 1, kind: 'glide', op_index: index)
      else
        ev.call(start, 'scroll', { 'dx' => op['dx'], 'dy' => op['dy'], 'block' => op['block'] }.compact)
        intervals << Interval.new(target: op['target'], from_frame: start, to_frame: start, kind: 'scroll', op_index: index)
      end
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def event(frame, kind, target, payload, op_index, sub = 0)
    Event.new(frame: frame, seq: SEQ.fetch(kind), kind: kind, target: target, payload: payload, op_index: op_index, sub: sub)
  end

  # Frames a span of `ms` covers: at least one.
  def span(ms, fps) = [ PrototypeCapture.frame_count(ms.to_i, fps), 1 ].max

  # A move or glide: one step per frame k in 1..n at eased progress k/n, the
  # last step exactly at the target (p 1.0, the full delta).
  def add_span(op, index, start, n, events, kind, easing)
    (1..n).each do |k|
      p = PrototypeCapture.ease(easing, k.to_f / n)
      payload = if kind == 'glide_step'
                  { 'dx' => (op['dx'].to_i * p).round(2), 'dy' => (op['dy'].to_i * p).round(2), 'first' => k == 1 }
      else
                  { 'p' => p, 'first' => k == 1 }
      end
      events << event(start + k - 1, kind, op['target'], payload, index, k)
    end
  end

  # A tap: the press on its frame, the release once press_ms has passed
  # (the real click), and with navigate a navigate on the release frame.
  def add_tap(op, index, start, fps, events, intervals)
    release = start + span(op['press_ms'] || PrototypeCapture::PRESS_MS, fps)
    navigate = op['navigate'] == true
    events << event(start, 'press', op['target'], {}, index)
    events << event(release, 'release', op['target'], { 'navigate' => navigate }, index)
    events << event(release, 'navigate', op['target'], { 'cut_frame' => release }, index) if navigate
    intervals << Interval.new(target: op['target'], from_frame: start, to_frame: release, kind: 'press', op_index: index)
  end

  # One event per character on the frame it lands; the first carries the
  # focus, caret placement and replace a type op starts with.
  def add_type(op, index, fps, events)
    cps = (op['cps'] || 12).to_f
    op['text'].to_s.each_char.with_index do |char, k|
      frame = PrototypeCapture.frame_at(op['t_ms'].to_i + (k * 1000.0 / cps), fps)
      payload = { 'char' => char, 'focus' => k.zero? }
      payload['after_line'] = op['after_line'] if k.zero? && op['after_line']
      payload['replace'] = true if k.zero? && op['replace']
      events << event(frame, 'type_char', op['target'], payload, index, k)
    end
  end

  # The per-frame plan the frame lint and older callers read, rendered from
  # the timeline: for a board without glides or taps, exactly the entries
  # the scheduler always produced (later ops overwrite a frame's move,
  # hover, click, dblclick and scroll; type text and key presses append).
  def to_plan(timeline)
    plan = Array.new(timeline.frames) { |i| { 'frame' => i } }
    timeline.events.sort_by { |e| [ e.op_index, e.frame, e.sub ] }.each do |e|
      entry = plan[e.frame] or next
      plan_entry(entry, e)
    end
    plan
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def plan_entry(entry, e)
    case e.kind
    when 'move_step' then entry['move'] = { 'target' => e.target, 'p' => e.payload['p'], 'first' => e.payload['first'] }
    when 'click', 'dblclick', 'hover' then entry[e.kind] = e.target
    when 'key' then (entry['key'] ||= []) << { 'keys' => e.payload['keys'], 'target' => e.target }.compact
    when 'scroll' then entry['scroll'] = { 'target' => e.target }.merge(e.payload)
    when 'glide_step' then (entry['glide'] ||= []) << { 'target' => e.target }.merge(e.payload)
    when 'press' then (entry['press'] ||= []) << e.target
    when 'release' then (entry['tap'] ||= []) << { 'target' => e.target, 'navigate' => e.payload['navigate'] }
    when 'type_char' then plan_type(entry, e)
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def plan_type(entry, e)
    k = e.sub
    entry['type'] ||= { 'target' => e.target, 'text' => +'', 'focus' => k.zero? }
    entry['type']['text'] << e.payload['char']
    entry['type']['focus'] ||= k.zero?
    entry['type']['after_line'] = e.payload['after_line'] if e.payload['after_line']
    entry['type']['replace'] = true if e.payload['replace']
  end

  # -- navigate pairs --------------------------------------------------------
  #
  # A tap with navigate: true hands its scene to the next one by order. The
  # two capture as one continuous run, split at the cut (the tap's release
  # frame): the tapping scene ends at the cut plus the next scene's
  # transition overlap, so the transition starts at the tap, and the next
  # scene's frame 0 is the run's cut frame.

  def scene_list(board) = Array(board['scenes']).sort_by { |s| s['order'].to_i }

  # [device, op] of a scene's navigate tap, or nil. A shared list taps on
  # the scene's lead device, whose name the caller passes.
  def navigate_tap(scene, lead)
    list = scene['interactions']
    lists = list.is_a?(Hash) ? list.to_a : [ [ lead, list ] ]
    lists.each do |device, ops|
      op = Array(ops).find { |o| navigate_op?(o) }
      return [ device, op ] if op
    end
    nil
  end

  def navigate_op?(op) = op.is_a?(Hash) && op['op'] == 'tap' && op['navigate'] == true

  def next_scene(board, scene)
    list = scene_list(board)
    i = list.index { |s| s['id'] == scene['id'] }
    i && list[i + 1]
  end

  # Frames the next scene's transition overlaps the tapping scene by: what
  # WalkthroughStoryboard.timeline uses, 0 for a cut.
  def overlap_frames(board, nxt, fps)
    index = scene_list(board).index { |s| s['id'] == nxt['id'] }.to_i
    transition = WalkthroughTransition.resolve(board, nxt, index)
    WalkthroughTransition.overlaps?(transition) ? PrototypeCapture.frame_at(transition['ms'].to_i, fps) : 0
  end

  # The cut of a tapping scene, or nil: { device, cut_frame, press_frame,
  # overlap, frames } with frames = cut_frame + overlap, the scene's
  # trimmed length. `lead` is the scene's first device's name.
  def cut(board, scene, lead:, fps:)
    device, op = navigate_tap(scene, lead)
    return nil unless op

    press = PrototypeCapture.frame_at(op['t_ms'].to_i, fps)
    release = press + span(op['press_ms'] || PrototypeCapture::PRESS_MS, fps)
    nxt = next_scene(board, scene)
    overlap = nxt ? overlap_frames(board, nxt, fps) : 0
    { 'device' => device, 'cut_frame' => release, 'press_frame' => press, 'overlap' => overlap, 'frames' => release + overlap }
  end

  # The ms that frame_count turns back into exactly `frames` frames.
  def frames_ms(frames, fps) = (frames * 1000).div(fps)

  # Whether ops use a key only the timeline gives meaning to (a glide or a
  # tap), so their frames key carries VERSION.
  def fluid?(ops) = Array(ops).any? { |op| op.is_a?(Hash) && (op['op'] == 'tap' || (op['op'] == 'scroll' && op.key?('ms'))) }
end
