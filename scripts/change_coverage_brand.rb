#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require_relative 'color_math'

# Turns a repo's qa_report brand declaration (QaReportConfig::Brand) into the
# exact tokens the QA coverage page bakes in: a light and a dark set of hex
# colors, a font stack, and logo data URIs.
#
# All color math happens here, in Ruby, so the page needs no script to apply
# a brand and a contrast problem is caught, fixed and reported at build time:
#
# - A theme declares only ground, ink and accent. Surface, border, muted,
#   accent-text, focus and on-accent are derived by sRGB mixing (what
#   `color-mix(in srgb)` does in a browser).
# - An accent too light for text keeps its declared hex on non-text marks
#   (bars, the header rule); text and focus use it stepped toward ink until
#   4.5:1, with a warning naming the slot and both ratios.
# - Ink is stepped away from ground until it reads at 4.5:1 on ground and on
#   surface, so the text colors stepped toward it can always get there too.
#   Every text ratio reported is the worse of ground and surface, and a step
#   that never meets its target warns by slot.
# - An undeclared dark theme swaps ground and ink and lifts the accent.
# - No brand, or an unusable light theme, yields a fixed neutral set copied
#   from artifact.html.erb, not derived. A dark-only brand keeps that neutral
#   light set and warns.
#
# The font is a family name only, followed by the system stack; nothing is
# embedded. A logo must sit inside the repo root, be at most 256 KB, and be a
# PNG, JPEG, WebP or SVG by its bytes; it is embedded only as an <img> data
# URI, never inlined into the DOM, so an SVG logo cannot run script.
#
# Never raises on bad input: each problem is a warning and a fallback.
module ChangeCoverageBrand
  Resolved = Data.define(:name, :title, :font_stack, :logo_uri, :logo_dark_uri, :light, :dark, :warnings)

  # The order is the order the page declares them in.
  TOKENS = %w[ground ink surface border muted accent accent-text focus on-accent].freeze

  NEUTRAL_LIGHT = {
    'ground' => '#ffffff', 'ink' => '#16181d', 'surface' => '#f7f8fa', 'border' => '#e3e6ea',
    'muted' => '#5c6370', 'accent' => '#1a4fd6', 'accent-text' => '#1a4fd6', 'focus' => '#1a4fd6',
    'on-accent' => '#ffffff'
  }.freeze
  NEUTRAL_DARK = {
    'ground' => '#14161a', 'ink' => '#e8eaee', 'surface' => '#1b1e24', 'border' => '#2a2e35',
    'muted' => '#9aa2ad', 'accent' => '#7aa2ff', 'accent-text' => '#7aa2ff', 'focus' => '#7aa2ff',
    'on-accent' => '#14161a'
  }.freeze

  # Fixed status colors (artifact.html.erb); a brand never changes them.
  STATUS = {
    'light' => { 'pass' => '#1f7a4d', 'warn' => '#8a6100', 'fail' => '#b3261e' },
    'dark' => { 'pass' => '#4cc38a', 'warn' => '#e0b341', 'fail' => '#ff6b60' }
  }.freeze

  SYSTEM_STACK = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif'
  FONT_FAMILY = /\A[A-Za-z0-9 ,'"-]+\z/
  SLOTS = %w[ground ink accent].freeze

  TEXT = 4.5
  NON_TEXT = 3.0
  STEP = 0.05
  SURFACE_MIX = 0.04
  BORDER_MIX = 0.14
  MUTED_START = 0.40

  LOGO_MAX_BYTES = 256 * 1024
  PREFIX = 'qa_report.brand'

  module_function

  # settings: a QaReportConfig::Settings (or nil when there is no CHANGE.md).
  def resolve(settings, repo_root:)
    Resolver.new(settings, repo_root).resolved
  end

  # WCAG ratio, floored to one decimal so a reported ratio never rounds up
  # past a threshold it misses.
  def shown_ratio(ratio) = (ratio * 10).floor / 10.0

  def contrast(a, b) = ColorMath.contrast_ratio(ColorMath.hex(a), ColorMath.hex(b))

  def mix_hex(a, b, t) = ColorMath.to_hex(ColorMath.mix(ColorMath.hex(a), ColorMath.hex(b), t))

  # Steps `from` toward `toward` in STEP increments until the block accepts
  # the candidate, returning [hex, steps taken, accepted]. Stops at `toward`
  # itself, with accepted false when even that fails the block.
  def step_until(from, toward, start: 0.0)
    t = start
    loop do
      candidate = mix_hex(from, toward, t)
      met = yield(candidate)
      return [ candidate, ((t - start) / STEP).round, met ] if met || t >= 1.0

      t = [ t + STEP, 1.0 ].min
    end
  end

  # Builds one Resolved. Holds the warnings list the derivations append to.
  class Resolver
    def initialize(settings, repo_root)
      @settings = settings
      @brand = settings&.brand
      @root = repo_root
      @warnings = []
    end

    def resolved
      name = @brand&.name.to_s.strip
      name = File.basename(File.expand_path(@root.to_s)) if name.empty?
      title = @settings&.title.to_s.strip
      light, dark = themes
      Resolved.new(
        name: name, title: title.empty? ? "#{name} QA coverage" : title,
        font_stack: font_stack, logo_uri: logo(@brand&.logo, 'logo'),
        logo_dark_uri: logo(@brand&.logo_dark, 'logo_dark'),
        light: light, dark: dark, warnings: @warnings
      )
    end

    private

    def warn(message) = @warnings << message

    def themes
      light_slots = slots(@brand&.light, 'light', 'neutral')
      dark_slots = slots(@brand&.dark, 'dark', light_slots ? 'derived' : 'neutral')
      warn_light_missing if dark_slots && @brand.light.nil?
      light = light_slots ? derive(light_slots, 'light') : ChangeCoverageBrand::NEUTRAL_LIGHT.dup
      dark =
        if dark_slots then derive(dark_slots, 'dark')
        elsif light_slots then derive(swap(light), 'dark', derived: true)
        else ChangeCoverageBrand::NEUTRAL_DARK.dup
        end
      [ light, dark ]
    end

    # A brand dark theme beside the neutral light one would mix two
    # identities on one page, so the user is asked to declare both.
    def warn_light_missing
      warn("#{PREFIX}.colors.light: not declared; the light theme uses the neutral set beside the brand " \
           "dark theme; declare #{PREFIX}.colors.light to brand both")
    end

    # Re-checks a declared theme even though QaReportConfig already did, so a
    # hand-built Brand cannot carry anything but hex into the page's CSS.
    def slots(theme, name, fallback)
      return nil if theme.nil?

      values = SLOTS.to_h { |slot| [ slot, theme[slot.to_sym] || theme[slot] ] }
      bad = values.reject { |_, v| ColorMath.hex(v) }
      return values.transform_values { |v| ColorMath.to_hex(ColorMath.hex(v)) } if bad.empty?

      bad.each_key { |slot| warn("#{PREFIX}.colors.#{name}.#{slot}: expected #rgb or #rrggbb (got #{values[slot].inspect})") }
      warn("#{PREFIX}.colors.#{name}: theme not used; falling back to the #{fallback} #{name} theme")
      nil
    end

    # The undeclared dark theme: ground and ink trade places and the light
    # accent is stepped toward the new ink until it reads as a mark (3:1).
    def swap(light)
      ground = light['ink']
      ink = light['ground']
      accent, _, met = ChangeCoverageBrand.step_until(light['accent'], ink) do |c|
        ChangeCoverageBrand.contrast(c, ground) >= NON_TEXT
      end
      unless met
        warn("#{slot_name('dark', 'accent', derived: true)} #{accent} is " \
             "#{ChangeCoverageBrand.shown_ratio(ChangeCoverageBrand.contrast(accent, ground))}:1 on ground; below #{NON_TEXT}:1")
      end
      { 'ground' => ground, 'ink' => ink, 'accent' => accent }
    end

    def slot_name(theme, slot, derived: false)
      "#{PREFIX}.colors.#{theme}.#{slot}#{derived ? ' (derived from light)' : ''}"
    end

    def derive(slots, theme, derived: false)
      ground = slots['ground']
      ink = readable_ink(slots['ink'], ground, slot_name(theme, 'ink', derived: derived))
      accent = slots['accent']
      surface = ChangeCoverageBrand.mix_hex(ground, ink, SURFACE_MIX)
      border = ChangeCoverageBrand.mix_hex(ground, ink, BORDER_MIX)
      backgrounds = [ ground, surface ]
      muted, _, met = ChangeCoverageBrand.step_until(ground, ink, start: MUTED_START) { |c| worst(c, *backgrounds) >= TEXT }
      warn("#{ratio_on(slot_name(theme, 'muted', derived: derived), muted, worst(muted, *backgrounds))}; below #{TEXT}:1") unless met
      accent_text = accent_for_text(accent, ink, backgrounds, slot_name(theme, 'accent', derived: derived))
      warn_status(theme, ground, "#{PREFIX}.colors.#{theme}")
      {
        'ground' => ground, 'ink' => ink, 'surface' => surface, 'border' => border, 'muted' => muted,
        'accent' => accent, 'accent-text' => accent_text, 'focus' => accent_text,
        'on-accent' => on_accent(accent, ground, ink)
      }
    end

    # The lower of a color's ratios on ground and on surface: text sits on both.
    def worst(color, ground, surface) = [ ground, surface ].map { |bg| ChangeCoverageBrand.contrast(color, bg) }.min

    # Ink under 4.5:1 on its ground or on the surface it derives is stepped
    # away from the ground (toward black or white, whichever contrasts more)
    # and reported. Ink that holds on both lets muted and accent text, which
    # step toward it, always reach 4.5:1 as well.
    def readable_ink(ink, ground, slot)
      ink_ratio = ->(c) { worst(c, ground, ChangeCoverageBrand.mix_hex(ground, c, SURFACE_MIX)) }
      before = ink_ratio.call(ink)
      return ink if before >= TEXT

      extreme = ChangeCoverageBrand.contrast('#000000', ground) >= ChangeCoverageBrand.contrast('#ffffff', ground) ? '#000000' : '#ffffff'
      fixed, = ChangeCoverageBrand.step_until(ink, extreme) { |c| ink_ratio.call(c) >= TEXT }
      warn(ratio_message(slot, ink, before, 'text uses', fixed, ink_ratio.call(fixed)))
      fixed
    end

    def accent_for_text(accent, ink, backgrounds, slot)
      fixed, steps = ChangeCoverageBrand.step_until(accent, ink) { |c| worst(c, *backgrounds) >= TEXT }
      return accent if steps.zero?

      warn(ratio_message(slot, accent, worst(accent, *backgrounds), 'text and focus use', fixed, worst(fixed, *backgrounds)))
      fixed
    end

    # "<slot> <color> is <ratio>:1 on ground or surface", the ratio floored.
    def ratio_on(slot, color, ratio) = "#{slot} #{color} is #{ChangeCoverageBrand.shown_ratio(ratio)}:1 on ground or surface"

    def ratio_message(slot, declared, before, uses, fixed, after)
      short = after >= TEXT ? '' : ", still below #{TEXT}:1"
      "#{ratio_on(slot, declared, before)}; #{uses} #{fixed} (#{ChangeCoverageBrand.shown_ratio(after)}:1#{short})"
    end

    def on_accent(accent, ground, ink)
      ChangeCoverageBrand.contrast(ground, accent) >= ChangeCoverageBrand.contrast(ink, accent) ? ground : ink
    end

    # Status colors are fixed, so a brand ground they do not stand out on is
    # only reported; every status also carries a text label on the page.
    def warn_status(theme, ground, slot)
      ChangeCoverageBrand::STATUS.fetch(theme).each do |status, color|
        ratio = ChangeCoverageBrand.contrast(color, ground)
        next if ratio >= NON_TEXT

        warn("#{slot}.ground #{ground}: status #{status} #{color} is #{ChangeCoverageBrand.shown_ratio(ratio)}:1; " \
             'status marks keep their text labels')
      end
    end

    def font_stack
      family = @brand&.font_family
      return SYSTEM_STACK if family.nil? || family.to_s.strip.empty?

      family = family.to_s.strip
      unless family.length <= 200 && family.match?(FONT_FAMILY)
        warn("#{PREFIX}.font.family: expected letters, digits, spaces and , ' \" - only; using the system stack")
        return SYSTEM_STACK
      end
      names = quoted_families(family)
      names.empty? ? SYSTEM_STACK : "#{names}, #{SYSTEM_STACK}"
    end

    # Each declared family as a quoted CSS string: an unquoted name such as
    # Source Sans 3 is not a valid identifier sequence and would void the
    # whole declaration.
    def quoted_families(family)
      family.split(',').map { |name| name.delete(%q("')).strip }.reject(&:empty?).map { |name| %("#{name}") }.join(', ')
    end

    def logo(path, field)
      return nil if path.nil? || path.to_s.strip.empty?

      data, problem = read_logo(path.to_s)
      if problem
        warn("#{PREFIX}.#{field}: #{path} #{problem}; header shows the name only")
        return nil
      end
      mime, bytes = data
      "data:#{mime};base64,#{Base64.strict_encode64(bytes)}"
    end

    def read_logo(path)
      return [ nil, 'must be relative to the repo root' ] if path.start_with?('/', '~')

      root = File.realpath(@root)
      full = File.expand_path(path, root)
      return [ nil, 'resolves outside the repo root' ] unless full.start_with?("#{root}/")
      return [ nil, 'was not found' ] unless File.file?(full)

      real = File.realpath(full)
      return [ nil, 'resolves outside the repo root' ] unless real.start_with?("#{root}/")
      return [ nil, "is over #{LOGO_MAX_BYTES / 1024} KB" ] if File.size(real) > LOGO_MAX_BYTES

      bytes = File.binread(real)
      mime = ChangeCoverageBrand.sniff(bytes)
      mime ? [ [ mime, bytes ], nil ] : [ nil, 'is not a PNG, JPEG, WebP or SVG' ]
    rescue SystemCallError => e
      [ nil, "could not be read (#{e.class})" ]
    end
  end

  # The image type by its leading bytes, never by its extension.
  def sniff(bytes)
    return 'image/png' if bytes.start_with?("\x89PNG".b)
    return 'image/jpeg' if bytes.start_with?("\xFF\xD8\xFF".b)
    return 'image/webp' if bytes.bytesize >= 12 && bytes.byteslice(0, 4) == 'RIFF' && bytes.byteslice(8, 4) == 'WEBP'

    svg?(bytes) ? 'image/svg+xml' : nil
  end

  # UTF-8 text whose first element, after an optional XML declaration,
  # comments and a doctype, is <svg.
  def svg?(bytes)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    return false unless text.valid_encoding?

    text = text.delete_prefix("\uFEFF")
    loop do
      stripped = text.lstrip.sub(/\A<\?xml\b.*?\?>/m, '').lstrip.sub(/\A<!--.*?-->/m, '').lstrip.sub(/\A<!DOCTYPE\b[^>]*>/mi, '')
      break if stripped == text

      text = stripped
    end
    text.lstrip.match?(/\A<svg[\s>\/]/)
  end
end
