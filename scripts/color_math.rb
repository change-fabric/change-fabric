#!/usr/bin/env ruby
# frozen_string_literal: true

# Small sRGB color math shared by the browser-backed cf:color checker: the
# WCAG relative-luminance and contrast-ratio formulas, alpha compositing
# ("flatten") over a backdrop, and a parser for the one color string shape
# the browser probe reports back, `color(srgb r g b)` or
# `color(srgb r g b / a)`, as produced by Chromium's computed-style
# serialization of a color-mix() result. Channels and alpha are floats in
# 0..1, clipped to that range (a color some color space can reach outside
# sRGB gamut is clipped rather than rejected, matching how a browser already
# gamut-maps what it hands back here).
module ColorMath
  Rgba = Data.define(:r, :g, :b, :a)

  WHITE = Rgba.new(r: 1.0, g: 1.0, b: 1.0, a: 1.0)

  NUMBER = /[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/.freeze
  COLOR_SRGB = /\Acolor\(srgb\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})(?:\s*\/\s*(#{NUMBER}))?\s*\)\z/.freeze

  module_function

  # Parses a `color(srgb r g b)` or `color(srgb r g b / a)` string into an
  # Rgba, or returns nil for anything else (including nil itself, the shape
  # the browser probe returns for a name or value it could not resolve to a
  # color).
  def parse(str)
    return nil if str.nil?

    m = COLOR_SRGB.match(str.strip)
    return nil unless m

    r, g, b = m[1..3].map { |n| n.to_f.clamp(0.0, 1.0) }
    a = m[4] ? m[4].to_f.clamp(0.0, 1.0) : 1.0
    Rgba.new(r:, g:, b:, a:)
  end

  # Composites a possibly translucent color over an opaque backdrop,
  # returning an opaque Rgba.
  def flatten(rgba, over:)
    f = rgba.a
    r = (rgba.r * f) + (over.r * (1 - f))
    g = (rgba.g * f) + (over.g * (1 - f))
    b = (rgba.b * f) + (over.b * (1 - f))
    Rgba.new(r: r.clamp(0.0, 1.0), g: g.clamp(0.0, 1.0), b: b.clamp(0.0, 1.0), a: 1.0)
  end

  def relative_luminance(rgba)
    rl, gl, bl = [ rgba.r, rgba.g, rgba.b ].map { |c| c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * rl) + (0.7152 * gl) + (0.0722 * bl)
  end

  def contrast_ratio(a, b)
    la = relative_luminance(a)
    lb = relative_luminance(b)
    lighter = [ la, lb ].max
    darker = [ la, lb ].min
    (lighter + 0.05) / (darker + 0.05)
  end
end
