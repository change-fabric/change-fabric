# frozen_string_literal: true

# Seeding a storyboard's story from a plan's story.json, and listing the
# questions still open. Mixed into WalkthroughStory's singleton, which owns the
# validation helpers (`empty?`, `outcomes?`) and QUESTIONS.
module WalkthroughStory
  module Seeding
    # Returns a new storyboard whose story is seeded from story.json. Absent
    # storyboard story: copied whole. Present: only absent or empty keys are
    # filled, a present value is never overwritten, scene arrays are never
    # seeded, and assumption pointers carry over only for fields copied.
    def seed(story_json, storyboard)
      board = Marshal.load(Marshal.dump(storyboard))
      source = story_json.is_a?(Hash) ? story_json : {}
      unless board['story'].is_a?(Hash)
        board['story'] = Marshal.load(Marshal.dump(source))
        return board
      end

      copied = []
      fill(board['story'], source.except('assumptions'), '/story', copied)
      pointers = carried_pointers(Array(source['assumptions']), copied)
      merged = (Array(board['story']['assumptions']) + pointers).uniq
      board['story']['assumptions'] = merged unless merged.empty?
      board
    end

    # A source pointer is carried for the part of it that was copied: itself
    # when it is a copied field or inside one, and the copied child when it
    # names a parent object only partly copied (the user's own values stay unmarked).
    def carried_pointers(pointers, copied)
      pointers.flat_map do |p|
        copied.filter_map do |c|
          if p == c || p.start_with?("#{c}/") then p
          elsif c.start_with?("#{p}/") then c
          end
        end
      end.uniq
    end

    def fill(dest, source, path, copied)
      source.each do |key, value|
        next if key == 'scenes'

        here = "#{path}/#{key}"
        if dest[key].is_a?(Hash) && value.is_a?(Hash)
          fill(dest[key], value, here, copied)
        elsif !dest.key?(key) || (empty?(dest[key]) && !empty?(value))
          dest[key] = scrub(Marshal.load(Marshal.dump(value)))
          copied << here
        end
      end
    end

    def scrub(value)
      return value unless value.is_a?(Hash)

      value.except('scenes').transform_values { |v| scrub(v) }
    end

    # Question keys still to ask. With assumed: true (the user is present) a
    # field recorded in story.assumptions counts as unanswered so the grill can
    # confirm it; away mode passes assumed: false.
    def unanswered(story, assumed: true)
      story = {} unless story.is_a?(Hash)
      pointers = Array(story['assumptions'])
      QUESTIONS.select do |q|
        !answered?(story, q) || (assumed && assumed?(pointers, "/story/#{q[:field].tr('.', '/')}"))
      end.map { |q| q[:key] }
    end

    # A pointer overlaps a field when it is the field, a value inside it, or
    # an object that contains it.
    def assumed?(pointers, field)
      pointers.any? { |p| p == field || p.start_with?("#{field}/") || field.start_with?("#{p}/") }
    end

    def answered?(story, question)
      parent, leaf = field_parent(story, question[:field])
      return false unless parent.is_a?(Hash) && parent.key?(leaf)

      value = parent[leaf]
      case question[:answered]
      when :non_empty then !empty?(value)
      when :outcomes then outcomes?(value)
      else true
      end
    end

    def field_parent(story, field)
      *path, leaf = field.split('.')
      [ path.reduce(story) { |node, seg| node.is_a?(Hash) ? node[seg] : nil }, leaf ]
    end
  end
end
