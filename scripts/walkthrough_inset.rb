# frozen_string_literal: true

require_relative 'prototype_ux_lint'

# The magnified inset: `inset` on a live scene picks one element by CSS
# selector, records its bounding box at `at_ms` during capture, and the
# frame composite crops that region from the captured frames and overlays it
# magnified for `duration_ms`, with a short fade in and out, in a corner of
# the safe area above the caption band. The device or browser frame is never
# resized (unlike a camera zoom), so the device-frame rule still holds, and
# the inset is drawn after the in-page UX lint ran, so the lint never sees
# it. At at_ms the capture also screenshots the padded element region at
# `scale` times the device pixel ratio (CDP clip.scale), so the inset is
# drawn from real pixels instead of an upscaled 1x crop; when that capture
# fails the composite falls back to the upscaled crop with a warning. Pure
# geometry and one filter chain here; FFmpeg runs in the scene
# composite (walkthrough_live.rb).
module WalkthroughInset
  KEYS = %w[selector at_ms duration_ms scale position].freeze
  POSITIONS = %w[top-right top-left bottom-right bottom-left].freeze
  SCALE = (1.25..4.0)
  DURATION_MS = (600..15_000)
  DEFAULT_SCALE = 2.0
  DEFAULT_POSITION = 'top-right'
  # Bumped when the drawn inset changes; it is key material.
  VERSION = 2
  FADE_MS = 200
  # CSS px of breathing room around the element before magnifying.
  PAD_CSS = 6
  # Safe-area margin as a share of the canvas height (as the frames use).
  MARGIN = 0.04
  BORDER = 3
  BORDER_COLOR = '0x2B2D33'

  Plan = Struct.new(:crop_x, :crop_y, :crop_w, :crop_h, :x, :y, :w, :h, :scale, :start, :stop, :fade, keyword_init: true) do
    def to_h = super.transform_keys(&:to_s)
  end

  module_function

  def inset?(scene) = scene.is_a?(Hash) && scene.key?('inset')

  def spec(scene)
    { 'scale' => DEFAULT_SCALE, 'position' => DEFAULT_POSITION }.merge(scene['inset'])
  end

  # -- validation ----------------------------------------------------------

  def errors(scene, live:)
    return [] unless inset?(scene)

    inset = scene['inset']
    return [ 'inset must be an object' ] unless inset.is_a?(Hash)

    errs = []
    errs << 'inset needs a live scene (screen.url)' unless live
    errs << 'inset magnifies the desktop; drop devices and layout' unless Array(scene['devices']).reject { |d| d == 'desktop' }.empty? && scene['layout'].nil?
    errs << 'inset and camera.zoom are exclusive (the inset keeps the frame size)' if scene.dig('camera', 'zoom').to_f > 1
    unknown = inset.keys - KEYS
    errs << "inset has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    errs << 'inset.selector must be a non-empty string' unless inset['selector'].is_a?(String) && !inset['selector'].strip.empty?
    errs << 'inset.at_ms must be a non-negative integer' unless inset['at_ms'].is_a?(Integer) && !inset['at_ms'].negative?
    errs << "inset.duration_ms must be an integer in #{DURATION_MS.min}..#{DURATION_MS.max}" unless inset['duration_ms'].is_a?(Integer) && DURATION_MS.cover?(inset['duration_ms'])
    errs << "inset.scale must be a number in #{SCALE.min}..#{SCALE.max}" if inset.key?('scale') && !(inset['scale'].is_a?(Numeric) && SCALE.cover?(inset['scale']))
    errs << "inset.position must be one of #{POSITIONS.join(', ')}" if inset.key?('position') && !POSITIONS.include?(inset['position'])
    errs
  end

  # The inset's part of a frames_key, or nil without one.
  def material(scene) = inset?(scene) ? { spec: spec(scene), version: VERSION } : nil

  # -- capture -------------------------------------------------------------

  # What the desktop capture job needs: the selector, the frame index at
  # which its bounding box is read, and the hi-res capture's scale and pad.
  def job(scene, fps)
    return nil unless inset?(scene)

    { 'selector' => scene['inset']['selector'], 'frame' => frame_at(scene['inset']['at_ms'], fps),
      'scale' => spec(scene)['scale'].to_f, 'pad' => PAD_CSS }
  end

  def frame_at(ms, fps) = (ms * fps / 1000.0).floor

  # -- geometry ------------------------------------------------------------

  def even(value) = (value / 2.0).floor * 2

  def band_top(canvas_h) = canvas_h * (1 - PrototypeUxLint::CAPTION_BAND)

  # Plans the inset on a composited layout. `box` is the element's bounding
  # box in viewport CSS px ({x, y, w, h}); `viewport_w` is the CSS width
  # the content rect shows. Content mapping goes through the layout's own
  # content rect, the single source of frame geometry, so a browser frame
  # or device layout is accounted for. `frames` caps the window.
  # rubocop:disable Metrics/AbcSize
  def plan(scene, lay, box, viewport_w:, fps:, frames:)
    sp = spec(scene)
    rect = lay.rects.find { |r| r.name == 'desktop' } || raise(ArgumentError, 'inset needs a desktop rect')
    k = rect.w.to_f / viewport_w
    vw, vh = viewport_w, rect.h / k
    x0 = (box['x'] - PAD_CSS).clamp(0, vw)
    y0 = (box['y'] - PAD_CSS).clamp(0, vh)
    x1 = (box['x'] + box['w'] + PAD_CSS).clamp(0, vw)
    y1 = (box['y'] + box['h'] + PAD_CSS).clamp(0, vh)
    crop_x = even(rect.x + (x0 * k))
    crop_y = even(rect.y + (y0 * k))
    crop_w = [ even((x1 - x0) * k), 2 ].max
    crop_h = [ even((y1 - y0) * k), 2 ].max
    margin = even(lay.canvas_h * MARGIN)
    room_w = lay.canvas_w - (2 * margin) - (2 * BORDER)
    room_h = band_top(lay.canvas_h) - (2 * margin) - (2 * BORDER)
    scale = [ sp['scale'].to_f, room_w.to_f / crop_w, room_h.to_f / crop_h ].min
    w = [ even(crop_w * scale), 2 ].max
    h = [ even(crop_h * scale), 2 ].max
    outer_w = w + (2 * BORDER)
    outer_h = h + (2 * BORDER)
    right = sp['position'].end_with?('right')
    bottom = sp['position'].start_with?('bottom')
    x = right ? lay.canvas_w - margin - outer_w : margin
    y = bottom ? (band_top(lay.canvas_h) - margin - outer_h).floor : margin
    start = frame_at(sp['at_ms'], fps)
    stop = [ frame_at(sp['at_ms'] + sp['duration_ms'], fps), frames ].min - 1
    fade = [ frame_at(FADE_MS, fps), 1 ].max
    Plan.new(crop_x: crop_x, crop_y: crop_y, crop_w: crop_w, crop_h: crop_h, x: x, y: y, w: w, h: h,
             scale: scale.round(4), start: start, stop: stop, fade: [ fade, ((stop - start + 1) / 2) ].min)
  end
  # rubocop:enable Metrics/AbcSize

  # The inset's on-canvas region, outer edge included: the area the UX
  # lint and caption check leave alone.
  def region(plan) = { 'x' => plan.x, 'y' => plan.y, 'w' => plan.w + (2 * BORDER), 'h' => plan.h + (2 * BORDER) }

  # -- compositing ---------------------------------------------------------

  # Appends the inset to a composite filter_complex ending in [out]. Fades
  # count frames (not timestamps), so the output is frame exact and
  # independent of the image sequence's nominal rate. `hires` is the input
  # index of the hi-res element still, or nil for the upscaled crop. The
  # still is laid over the upscaled crop (repeating its one frame), so the
  # crop stream still carries the frame timing and the fades.
  def append(filter, plan, hires: nil)
    return filter if plan.nil? || plan.stop < plan.start

    base = filter.delete_suffix('[out]')
    raise ArgumentError, 'composite filter must end in [out]' if base == filter

    src = "[cfsrc]#{crop(plan)}"
    src = "#{src}[cflo];[#{hires}:v]#{magnify(plan)}[cfhi];[cflo][cfhi]overlay=0:0:eof_action=repeat" if hires
    "#{base}[cfbase];[cfbase]split=2[cfbg][cfsrc];#{src},#{finish(plan)}[cfins];" \
      "[cfbg][cfins]overlay=x=#{plan.x}:y=#{plan.y}:enable='between(n,#{plan.start},#{plan.stop})'[out]"
  end

  # Crop, magnify, border, and fade the region.
  def chain(plan) = "#{crop(plan)},#{finish(plan)}"

  def crop(plan) = "crop=#{plan.crop_w}:#{plan.crop_h}:#{plan.crop_x}:#{plan.crop_y},#{magnify(plan)}"

  def finish(plan)
    region = region(plan)
    [
      "pad=#{region['w']}:#{region['h']}:#{BORDER}:#{BORDER}:color=#{BORDER_COLOR}", 'format=rgba',
      "fade=t=in:s=#{plan.start}:n=#{plan.fade}:alpha=1",
      "fade=t=out:s=#{plan.stop - plan.fade + 1}:n=#{plan.fade}:alpha=1"
    ].join(',')
  end

  def magnify(plan) = "scale=#{plan.w}:#{plan.h}:flags=lanczos"
end
