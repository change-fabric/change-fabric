# frozen_string_literal: true

require 'json'

# The walkthrough story block: a hero the audience recognizes as themselves and
# a before, turn and after spine anchored to scenes. It lives under the
# top-level `story` key of storyboard.json (and, without any scene ids, in a
# plan dir's story.json). Validation is pure; `preflight!` is the one gate every
# paid walkthrough call site runs before it spends money.
#
# The validator checks the hero for presence only. Whether the hero is the
# viewer's counterpart (and not the product or our team) is a judgment the
# roast makes, not a word list here.
module WalkthroughStory
  class MissingStoryError < StandardError; end

  PERSPECTIVES = %w[first second third].freeze
  SCOPES = %w[built_only wider].freeze
  FOOTAGE = %w[before after].freeze
  LENGTH_RANGE = (15..600)
  SPINE = %w[before turn after].freeze

  # One question table for cf:walkthrough step 2, cf:plan's walkthrough round
  # and `unanswered`. `answered` names the rule: :non_empty, :present (the key
  # exists; null and [] count) or :outcomes (at least one non-empty string).
  QUESTIONS = [
    { key: 'audience', question: 'Who watches this?', field: 'audience', required: true, answered: :non_empty },
    { key: 'hero', question: 'Who is the hero, as a role the viewer sees themselves in?', field: 'hero', required: true, answered: :non_empty },
    { key: 'guide', question: 'Who guides the hero (usually the product or our team)?', field: 'guide', required: false, answered: :present },
    { key: 'perspective', question: 'Whose voice tells it: first, second or third person?', field: 'perspective', required: false, answered: :present },
    { key: 'before', question: "What is the hero's problem state before?", field: 'before.state', required: true, answered: :non_empty },
    { key: 'turn', question: 'What moment turns it?', field: 'turn.moment', required: true, answered: :non_empty },
    { key: 'after', question: 'What outcomes does the hero have after?', field: 'after.outcomes', required: true, answered: :outcomes },
    { key: 'beats', question: 'Any beats in between?', field: 'beats', required: false, answered: :present },
    { key: 'length', question: 'Target length in seconds?', field: 'length_s', required: false, answered: :present },
    { key: 'ui_before_after', question: 'Show real old-UI versus new-UI footage?', field: 'highlights.ui_before_after', required: false, answered: :present },
    { key: 'scope', question: 'Only what we built, or wider?', field: 'highlights.scope', required: false, answered: :present },
    { key: 'secondary', question: 'Any secondary artifact to feature?', field: 'highlights.secondary_artifacts', required: false, answered: :present },
    { key: 'requests', question: 'Other special highlight requests?', field: 'highlights.requests', required: false, answered: :present }
  ].freeze

  module_function

  # Missing, null, a blank string or an empty array.
  def empty?(value)
    case value
    when nil then true
    when String then value.strip.empty?
    when Array then value.empty?
    else false
    end
  end

  def string?(value) = value.is_a?(String) && !value.strip.empty?

  def strings?(value) = value.is_a?(Array) && value.all? { |v| string?(v) }

  def outcomes?(value) = strings?(value) && !value.empty?

  # Validation errors. mode :story covers story.json and the story round
  # (scene arrays must be absent); mode :storyboard covers validate and render
  # and needs the whole board for scene ids, order and footage pairs.
  def errors(story, mode:, board: nil)
    return [ 'story is missing: run the story round (cf:walkthrough step 2)' ] if story.nil?
    return [ 'story must be an object' ] unless story.is_a?(Hash)

    ids = scene_ids(board)
    out = []
    out.concat(text_errors(story))
    out.concat(spine_errors(story, mode, ids))
    out.concat(beat_errors(story, mode, ids))
    out.concat(optional_errors(story))
    out.concat(highlight_errors(story, mode, board))
    out.concat(assumption_errors(story))
    out
  end

  def scene_ids(board)
    return [] unless board.is_a?(Hash) && board['scenes'].is_a?(Array)

    board['scenes'].map { |s| s.is_a?(Hash) ? s['id'] : nil }
  end

  def text_errors(story)
    out = []
    out << 'story.hero must be a non-empty string (the role the viewer sees themselves in)' unless string?(story['hero'])
    out << 'story.audience must be a non-empty string' unless string?(story['audience'])
    if story.key?('guide') && !story['guide'].nil? && !string?(story['guide'])
      out << 'story.guide must be a non-empty string or null'
    end
    if story.key?('perspective') && !PERSPECTIVES.include?(story['perspective'])
      out << "story.perspective must be one of #{PERSPECTIVES.join(', ')}"
    end
    out
  end

  # before, turn and after, each an object with its text field and (storyboard
  # mode) a non-empty scene list. The turn text field is `moment`.
  def spine_errors(story, mode, ids)
    out = []
    { 'before' => 'state', 'turn' => 'moment', 'after' => 'outcomes' }.each do |name, field|
      part = story[name]
      unless part.is_a?(Hash)
        out << "story.#{name} must be an object with #{field}#{mode == :storyboard ? ' and scenes' : ''}"
        next
      end
      out.concat(spine_field_errors(name, field, part))
      out.concat(spine_scene_errors("story.#{name}", part, mode, ids))
    end
    out.concat(order_errors(story, ids)) if mode == :storyboard
    out
  end

  def spine_field_errors(name, field, part)
    if field == 'outcomes'
      return [] if outcomes?(part[field])

      [ "story.#{name}.#{field} must be an array with at least one non-empty string" ]
    else
      string?(part[field]) ? [] : [ "story.#{name}.#{field} must be a non-empty string" ]
    end
  end

  # Story-only: the key must be absent.
  def absent_scenes_error(label, part)
    part.key?('scenes') ? [ "#{label}.scenes must be absent in story.json (scene ids are attached when scenes are authored)" ] : []
  end

  # A spine part's scene list: required and non-empty in storyboard mode.
  def spine_scene_errors(label, part, mode, ids)
    return absent_scenes_error(label, part) if mode == :story

    list = part['scenes']
    return [ "#{label}.scenes must be a non-empty array of scene ids" ] unless list.is_a?(Array) && !list.empty?

    unknown_id_errors(label, list, ids)
  end

  # A beat's scene list: optional.
  def beat_scene_errors(label, beat, mode, ids)
    return absent_scenes_error(label, beat) if mode == :story

    list = beat['scenes']
    return [] if list.nil?
    return [ "#{label}.scenes must be an array of scene ids" ] unless list.is_a?(Array)

    unknown_id_errors(label, list, ids)
  end

  def unknown_id_errors(label, list, ids)
    unknown = list.reject { |id| id.is_a?(String) && ids.include?(id) }
    unknown.empty? ? [] : [ "#{label}.scenes names unknown scene ids: #{unknown.map(&:inspect).join(', ')}" ]
  end

  # Index in the board's scenes array: max(before) < min(turn) and
  # max(turn) < min(after). Only checked once every list is well formed.
  def order_errors(story, ids)
    idx = SPINE.map { |name| spine_indexes(story[name], ids) }
    return [] if idx.any?(&:empty?)

    out = []
    out << 'story.before scenes must all come before story.turn scenes' unless idx[0].max < idx[1].min
    out << 'story.turn scenes must all come before story.after scenes' unless idx[1].max < idx[2].min
    out
  end

  def spine_indexes(part, ids)
    return [] unless part.is_a?(Hash) && part['scenes'].is_a?(Array)

    part['scenes'].filter_map { |id| ids.index(id) }
  end

  def beat_errors(story, mode, ids)
    return [] unless story.key?('beats')
    return [ 'story.beats must be an array of objects' ] unless story['beats'].is_a?(Array)

    story['beats'].each_with_index.flat_map do |beat, i|
      label = "story.beats[#{i}]"
      next [ "#{label} must be an object with a label" ] unless beat.is_a?(Hash)

      errs = string?(beat['label']) ? [] : [ "#{label}.label must be a non-empty string" ]
      errs + beat_scene_errors(label, beat, mode, ids)
    end
  end

  def optional_errors(story)
    return [] unless story.key?('length_s')

    v = story['length_s']
    return [] if v.is_a?(Integer) && LENGTH_RANGE.cover?(v)

    [ "story.length_s must be an integer from #{LENGTH_RANGE.min} to #{LENGTH_RANGE.max}" ]
  end

  def highlight_errors(story, mode, board)
    return [] unless story.key?('highlights')

    h = story['highlights']
    return [ 'story.highlights must be an object' ] unless h.is_a?(Hash)

    out = []
    out << 'story.highlights.ui_before_after must be true or false' if h.key?('ui_before_after') && ![ true, false ].include?(h['ui_before_after'])
    out << "story.highlights.scope must be one of #{SCOPES.join(', ')}" if h.key?('scope') && !SCOPES.include?(h['scope'])
    %w[secondary_artifacts requests].each do |k|
      out << "story.highlights.#{k} must be an array of non-empty strings" if h.key?(k) && !strings?(h[k])
    end
    out.concat(pair_errors(board)) if mode == :storyboard && h['ui_before_after'] == true
    out
  end

  # Storyboard only: a before scene and an after scene share a pair id, the
  # before scene earlier in the scenes array.
  def pair_errors(board)
    scenes = board.is_a?(Hash) && board['scenes'].is_a?(Array) ? board['scenes'].grep(Hash) : []
    pairs = scenes.each_with_index.select { |s, _| s['pair'] }.group_by { |s, _| s['pair'] }
    ok = pairs.any? do |_id, rows|
      b = rows.find { |s, _| s['footage'] == 'before' }
      a = rows.reverse.find { |s, _| s['footage'] == 'after' }
      b && a && b[1] < a[1]
    end
    return [] if ok

    [ 'story.highlights.ui_before_after is true but no pair exists: add a scene with footage "before" and a later scene with footage "after" sharing one pair id' ]
  end

  def assumption_errors(story)
    return [] unless story.key?('assumptions')
    return [ 'story.assumptions must be an array of JSON pointers' ] unless strings?(story['assumptions'])

    story['assumptions'].reject { |p| pointer_resolves?(story, p) }
                        .map { |p| "story.assumptions pointer #{p} does not resolve under /story" }
  end

  def pointer_resolves?(story, pointer)
    return false unless pointer.start_with?('/story/')

    node = story
    pointer.delete_prefix('/story/').split('/').each do |seg|
      found, node = step(node, seg)
      return false unless found
    end
    true
  end

  def step(node, seg)
    if node.is_a?(Hash)
      [ node.key?(seg), node[seg] ]
    elsif node.is_a?(Array) && seg.match?(/\A\d+\z/) && seg.to_i < node.size
      [ true, node[seg.to_i] ]
    else
      [ false, nil ]
    end
  end

  # Storyboard-mode errors for a whole board, raised as one message.
  def preflight!(board)
    errs = errors(board.is_a?(Hash) ? board['story'] : nil, mode: :storyboard, board: board)
    return true if errs.empty?

    raise MissingStoryError, errs.join("\n")
  end

  # CLI mains print this and exit with the code it returns.
  def report(error, out: $stderr)
    error.message.each_line { |l| out.puts("story: #{l.chomp}") }
    out.puts('run the story round (cf:walkthrough step 2)')
    2
  end

  # The same errors as `warning:` text, for validate and estimate-only runs.
  def warnings(board)
    errors(board.is_a?(Hash) ? board['story'] : nil, mode: :storyboard, board: board)
  end

  # A story.json, or a storyboard.json (its story key).
  def story_of(doc) = doc.is_a?(Hash) && doc.key?('story') ? doc['story'] : doc
end

require_relative 'walkthrough_story_seed'
WalkthroughStory.extend(WalkthroughStory::Seeding)

if __FILE__ == $PROGRAM_NAME
  usage = "usage: walkthrough_story.rb seed <story.json> <storyboard.json>\n       walkthrough_story.rb unanswered <story.json|storyboard.json> [--away]"
  cmd, a, b = ARGV
  abort(usage) unless a
  case cmd
  when 'seed'
    abort(usage) unless b
    board = WalkthroughStory.seed(JSON.parse(File.read(a)), JSON.parse(File.read(b)))
    File.write(b, "#{JSON.pretty_generate(board)}\n")
    puts "seeded #{b}"
  when 'unanswered'
    story = WalkthroughStory.story_of(JSON.parse(File.read(a)))
    puts WalkthroughStory.unanswered(story, assumed: !ARGV.include?('--away'))
  else abort(usage)
  end
end
