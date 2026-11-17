# frozen_string_literal: true

require 'json'
require_relative 'walkthrough_element'
require_relative 'walkthrough_live'
require_relative 'walkthrough_storyboard'

# Board copies for draft delivery. Pure functions: the authored board is
# never touched.
#
# Placeholders: a scene marked `pending: { reason }` (feature not deployed,
# waiting on a PR) renders as a titled element card (scene title plus
# reason) for the scene's planned duration, in the film's theme, keeping its
# narration, so a partial cut renders instead of blocking.
#
# Silent cut: the free first cut, before any paid narration or music. Music
# is dropped, each narrated scene holds its planned length with no voice,
# and every word anchor takes a provisional time: the anchor's
# fallback_t_ms when the board gives one, else evenly spaced across the
# scene in authored order.
module WalkthroughDraftBoard
  # Keys a placeholder keeps from its scene; the rest describe the picture
  # that cannot be filmed yet.
  PLACEHOLDER_KEEP = %w[id order title narration narration_start timing hypotheses requirements assumptions pending].freeze
  # Words per second for the planned length of a line with no measured_ms.
  WORDS_PER_SECOND = 2.5

  module_function

  def copy(board) = JSON.parse(JSON.generate(board))

  def pending?(scene) = scene.is_a?(Hash) && scene.key?('pending')

  def reason(scene) = scene.dig('pending', 'reason').to_s.strip

  # { id => reason } for every pending scene.
  def placeholders(board)
    WalkthroughStoryboard.scenes(board).select { |s| pending?(s) }.to_h { |s| [ s['id'], reason(s) ] }
  end

  def theme(board) = WalkthroughDiagram::THEMES.include?(board['theme']) ? board['theme'] : 'dark'

  def clip(text, max = WalkthroughElement::TEXT_CHARS)
    text = text.to_s.strip
    text.size <= max ? text : "#{text[0, max - 3].rstrip}..."
  end

  # A copy with every pending scene swapped for its placeholder card. A
  # scene that takes its session, link, or store from a placeholder cannot
  # be filmed either, so it becomes one too. A board with none is returned
  # as is, so the render keeps working on the caller's board.
  def with_placeholders(board)
    return board unless Array(board['scenes']).any? { |s| pending?(s) }

    out = copy(board)
    reasons = blocked(out)
    out['scenes'] = Array(out['scenes']).map { |s| reasons.key?(s['id']) ? placeholder(out, s, reasons[s['id']]) : s }
    out
  end

  PARENT_KEYS = [ %w[session_from_scene], %w[compose from_scene], %w[store from_scene] ].freeze

  # { id => reason } for the pending scenes, every scene whose parent is
  # one of them, and every scene whose navigate tap lands on one, repeated
  # until nothing more is blocked.
  def blocked(board)
    list = WalkthroughStoryboard.scenes(board)
    out = list.select { |sc| pending?(sc) }.to_h { |sc| [ sc['id'], reason(sc) ] }
    loop do
      added = list.each_cons(2).to_a.push([ list.last, nil ]).filter_map do |scene, nxt|
        next if out.key?(scene['id'])

        other = PARENT_KEYS.map { |path| scene.dig(*path) }.find { |id| out.key?(id) }
        other ||= nxt['id'] if nxt && out.key?(nxt['id']) && navigates?(scene)
        [ scene['id'], "needs scene #{other}, #{out[other]}" ] if other
      end
      return out if added.empty?

      out.merge!(added.to_h)
    end
  end

  def navigates?(scene)
    WalkthroughStoryboard.interaction_lists(scene).any? { |_, ops| ops.any? { |op| op.is_a?(Hash) && op['navigate'] == true } }
  end

  def placeholder(board, scene, why = reason(scene))
    planned = planned_ms(board, scene)
    card = scene.slice(*PLACEHOLDER_KEEP).merge('pending' => { 'reason' => why })
    card['kind'] = WalkthroughElement::KIND
    card['timing'] = (scene['timing'] || {}).merge('min_ms' => planned).except('duration_ms')
    title = clip(scene['title'].to_s.empty? ? scene['id'] : scene['title'])
    land = [ WalkthroughElement::ENTER_MS, planned / 4 ].min
    card['element'] = { 'theme' => theme(board),
                        'beats' => [ { 'id' => 'pending', 'type' => 'card', 'title' => title,
                                       'subtitle' => clip("Not filmed yet: #{why}"), 'land_at' => land } ] }
    card
  end

  # The scene's planned length: its derived duration, or with no measured
  # narration yet, its line read at WORDS_PER_SECOND.
  def planned_ms(board, scene)
    derived = WalkthroughLive.duration_ms(board, scene)
    text = scene.dig('narration', 'text').to_s
    return derived if text.strip.empty? || scene.dig('narration', 'measured_ms').to_i.positive?

    spoken = PrototypeCapture.narration_start_ms(scene) + (text.split.size * 1000 / WORDS_PER_SECOND).round +
             scene.dig('timing', 'pad_ms').to_i
    [ derived, spoken ].max
  end

  # The silent first cut of board (already carrying its placeholders).
  def silent(board)
    out = copy(board)
    out.delete('music')
    WalkthroughStoryboard.scenes(out).each { |scene| silence!(out, scene) }
    out
  end

  def silence!(board, scene)
    return unless scene['narration'].is_a?(Hash)

    duration = planned_ms(board, scene)
    provisional!(scene, duration, WalkthroughStoryboard.fps(board))
    scene['timing'] = (scene['timing'] || {}).merge('min_ms' => duration)
    scene.delete('narration')
    scene.delete('narration_start')
  end

  # Gives every anchor in the scene a plain scene-local time.
  def provisional!(scene, duration, fps)
    ops = WalkthroughStoryboard.interaction_lists(scene).map(&:last)
    ops.each { |list| place!(list, duration, fps) }
    place_steps!(scene, duration, fps)
    place_beats!(scene, duration, fps)
  end

  # Anchored ops in one list, evenly spaced, never before the op ahead.
  def place!(list, duration, fps)
    anchored = list.select { |op| op.is_a?(Hash) && op.key?('at') }
    rank = anchored.each_with_index.to_h.compare_by_identity
    floor = 0
    list.each do |op|
      next unless op.is_a?(Hash)

      if op.key?('at')
        at = op.delete('at')
        op['t_ms'] = [ time(at, rank[op], anchored.size, duration, fps), floor ].max
      end
      floor = op['t_ms'] if op['t_ms'].is_a?(Integer)
    end
  end

  def place_steps!(scene, duration, fps)
    steps = WalkthroughElement.anchored_steps(scene)
    steps.each_with_index { |step, i| step['t_ms'] = time(step.delete('at'), i, steps.size, duration, fps) }
  end

  # Anchored landings spaced evenly; an anchored exit halfway to the next
  # landing (or to the scene end).
  def place_beats!(scene, duration, fps)
    return unless WalkthroughElement.element?(scene)

    beats = WalkthroughElement.beats(scene)
    beats.each_with_index do |beat, i|
      beat['land_at'] = time(beat['land_at'], i, beats.size, duration, fps) if beat['land_at'].is_a?(Hash)
    end
    beats.each_with_index do |beat, i|
      next unless beat['exit_at'].is_a?(Hash)

      fallback = beat['exit_at']['fallback_t_ms']
      nxt = beats[i + 1]&.dig('land_at')
      stop = nxt.is_a?(Integer) ? nxt - WalkthroughElement::ENTER_MS : duration - WalkthroughElement::EXIT_MS
      beat['exit_at'] = fallback.is_a?(Integer) ? fallback : WalkthroughStoryboard.snap_ms((beat['land_at'] + stop) / 2, fps)
    end
  end

  def time(at, index, count, duration, fps)
    return at['fallback_t_ms'] if at.is_a?(Hash) && at['fallback_t_ms'].is_a?(Integer)

    WalkthroughStoryboard.snap_ms(duration * (index + 1) / (count + 1), fps)
  end
end
