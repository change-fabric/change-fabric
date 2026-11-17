# frozen_string_literal: true

# The opt-in film look: grain and a vignette, set by the board's `look`
# ({ "grain": 0..30, "vignette": true | false | radians }) and chosen per
# film through cf:imagine. Off by default. A look with nothing on plans to
# nil, so its render argv is byte-identical to a board with no `look`.
# Grain is FFmpeg temporal noise on a fixed seed, so a frame renders the
# same bytes every time.
module WalkthroughLook
  FIELDS = %w[grain vignette].freeze
  GRAIN = (0..30)
  SEED = 1729
  # FFmpeg's own vignette default, pi/5.
  DEFAULT_ANGLE = (Math::PI / 5).round(4)
  MAX_ANGLE = (Math::PI / 2).round(4)

  module_function

  def errors(look)
    return [] if look.nil?
    return [ 'look must be an object' ] unless look.is_a?(Hash)

    errs = (look.keys - FIELDS).map { |k| "look.#{k} is not a known field (#{FIELDS.join(', ')})" }
    errs << "look.grain must be an integer from #{GRAIN.min} to #{GRAIN.max}" if look.key?('grain') && !grain?(look['grain'])
    if look.key?('vignette') && !vignette?(look['vignette'])
      errs << "look.vignette must be true, false, or an angle in radians above 0 and at most #{MAX_ANGLE}"
    end
    errs
  end

  def grain?(value) = value.is_a?(Integer) && GRAIN.cover?(value)

  def vignette?(value) = [ true, false ].include?(value) || (value.is_a?(Numeric) && value.positive? && value <= MAX_ANGLE)

  # { grain:, vignette: } with only the parts that are on, or nil when the
  # look is absent, invalid, or entirely off.
  def plan(board)
    look = board['look']
    return nil if look.nil? || !errors(look).empty?

    out = {}
    out[:grain] = look['grain'] if look['grain'].to_i.positive?
    v = look['vignette']
    out[:vignette] = v == true ? DEFAULT_ANGLE : v.to_f.round(4) if v
    out.empty? ? nil : out
  end

  # The FFmpeg filter chain for a planned look.
  def filter(look)
    parts = []
    parts << "noise=alls=#{look[:grain]}:allf=t:all_seed=#{SEED}" if look[:grain]
    parts << "vignette=angle=#{format('%.4f', look[:vignette])}:eval=init" if look[:vignette]
    parts.join(',')
  end
end
