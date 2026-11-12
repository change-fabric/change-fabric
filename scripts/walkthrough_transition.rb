# frozen_string_literal: true

# Scene transitions: the move into a scene from the one before it. A scene's
# timing.transition wins over the board-level `transition` default; the first
# scene never has one. Every type but `cut` overlaps the previous scene by its
# ms. `fade` without an `ease` is the original linear xfade, kept exactly; any
# other transition is an xfade custom expression with a real easing curve
# (the pinned FFmpeg 7.1 xfade has no easing option of its own).
module WalkthroughTransition
  TYPES = %w[cut fade crossfade slide-left slide-up push].freeze
  EASES = %w[linear ease-in ease-out ease-in-out].freeze
  MS = (100..1500)
  DEFAULT_MS = 350
  DEFAULT_EASE = 'ease-in-out'
  CUT = { 'type' => 'cut', 'ms' => 0 }.freeze

  module_function

  def errors(transition, where = 'transition')
    return [] if transition.nil?
    return [ "#{where} must be an object" ] unless transition.is_a?(Hash)

    type = transition['type']
    return [ "#{where}.type #{type.inspect} must be one of #{TYPES.join(', ')}" ] unless TYPES.include?(type)
    return [] if type == 'cut'

    out = []
    ms = transition['ms']
    if type == 'fade'
      out << "fade #{where} ms must be in #{MS.min}..#{MS.max}" unless MS.cover?(ms.to_i)
    elsif !ms.nil? && !(ms.is_a?(Integer) && MS.cover?(ms))
      out << "#{where}.ms must be an integer in #{MS.min}..#{MS.max}"
    end
    ease = transition['ease']
    out << "#{where}.ease #{ease.inspect} must be one of #{EASES.join(', ')}" unless ease.nil? || EASES.include?(ease)
    out
  end

  # The transition into scene `index` (0-based, in order), with defaults
  # filled. A board without the new keys gets back exactly what it authored.
  def resolve(board, scene, index)
    authored = scene.dig('timing', 'transition') || (index.positive? ? board['transition'] : nil)
    return CUT if authored.nil?
    return authored if authored['type'] == 'cut' || legacy_fade?(authored)

    authored.merge('ms' => authored['ms'] || DEFAULT_MS, 'ease' => authored['ease'] || DEFAULT_EASE)
  end

  def legacy_fade?(transition) = transition['type'] == 'fade' && transition['ease'].nil?

  def overlaps?(transition) = !transition.nil? && TYPES.include?(transition['type']) && transition['type'] != 'cut'

  # The xfade filter (without its pads) for one overlapping transition.
  def xfade(transition, duration:, offset:)
    timing = "duration=#{duration}:offset=#{offset}"
    return "xfade=transition=fade:#{timing}" if legacy_fade?(transition)

    "xfade=transition=custom:#{timing}:expr='#{expression(transition)}'"
  end

  # Per-pixel expression. xfade's P runs 1 to 0 over the overlap, so the
  # progress is 1-P; X, Y, W, H are the current plane's, so a shift stays
  # proportional on subsampled chroma planes.
  def expression(transition)
    e = eased(transition['ease'] || DEFAULT_EASE)
    case transition['type']
    when 'push'
      s = "floor(#{e}*W)"
      "if(lt(X+#{s},W),#{sample('a', "X+#{s}", 'Y')},#{sample('b', "X+#{s}-W", 'Y')})"
    when 'slide-left'
      s = "floor(#{e}*W)"
      "if(gte(X,W-#{s}),#{sample('b', "X-W+#{s}", 'Y')},A)"
    when 'slide-up'
      s = "floor(#{e}*H)"
      "if(gte(Y,H-#{s}),#{sample('b', 'X', "Y-H+#{s}")},A)"
    else
      "A*(1-#{e})+B*#{e}"
    end
  end

  # Eased progress in 0..1 (cubic curves); 1-P is linear progress.
  def eased(ease)
    case ease
    when 'ease-in' then 'pow(1-P,3)'
    when 'ease-out' then '(1-pow(P,3))'
    when 'ease-in-out' then 'if(lt(1-P,0.5),4*pow(1-P,3),1-pow(2*P,3)/2)'
    else '(1-P)'
    end
  end

  # One input's pixel at (x, y) on the current plane.
  def sample(input, x, y)
    (0..2).reverse_each.reduce("#{input}3(#{x},#{y})") do |acc, plane|
      "if(eq(PLANE,#{plane}),#{input}#{plane}(#{x},#{y}),#{acc})"
    end
  end
end
