# frozen_string_literal: true

require_relative 'prototype_capture'
require_relative 'prototype_ux_lint'

# Which devices a live or compose scene is filmed on, and where each lands
# on the board canvas. `devices` is ["desktop"] (the default, the board
# viewport, full bleed as before), ["phone"], or ["desktop", "phone"];
# `layout` is single or side_by_side (both devices in one shot). A phone is
# captured at the board's `phone` spec under mobile emulation, scaled to fit
# above the caption band inside a simple bezel on a neutral canvas.
module WalkthroughDevice
  DEVICES = %w[desktop phone].freeze
  LAYOUTS = %w[single side_by_side].freeze
  PHONE_KEYS = %w[w h dpr ua].freeze
  SIZE = (100..4000)
  DPR = (1..4)
  DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) ' \
               'Chrome/130.0.0.0 Mobile Safari/537.36'
  DEFAULT_PHONE = { 'w' => 390, 'h' => 844, 'dpr' => 2, 'ua' => DEFAULT_UA }.freeze
  # Bezel thickness in device CSS px (phone) and canvas px (desktop frame).
  PHONE_BEZEL_CSS = 14
  DESKTOP_BEZEL = 6
  MARGIN = 0.04
  GAP = 0.03
  CANVAS = '0xE6E7EB'
  BEZEL = '0x16171A'
  RIPPLE = 44
  RIPPLE_FRAMES = 9
  # Where an idle sprite is parked: fully left of and above the canvas, so
  # overlay draws nothing.
  OFF_CANVAS = -RIPPLE * 5

  Size = Struct.new(:w, :h)

  # One device's screen on the canvas: `scale` is canvas px per device CSS
  # px, x/y/w/h the screen, `bezel` the frame thickness around it.
  Rect = Struct.new(:name, :scale, :x, :y, :w, :h, :bezel, keyword_init: true) do
    def outer_x = x - bezel
    def outer_y = y - bezel
    def outer_w = w + (2 * bezel)
    def outer_h = h + (2 * bezel)
    def bottom = outer_y + outer_h
    def map(px, py) = [ x + (px * scale), y + (py * scale) ]
  end

  Layout = Struct.new(:rects, :canvas_w, :canvas_h, keyword_init: true) do
    def rect(name) = rects.find { |r| r.name == name }
  end

  module_function

  def devices(scene) = Array(scene['devices']).empty? ? [ 'desktop' ] : scene['devices']

  def layout_name(scene) = scene['layout'] || 'single'

  def phone(board) = DEFAULT_PHONE.merge(board['phone'] || {})

  def board_viewport(board) = PrototypeCapture::DEFAULT_VIEWPORT.merge(board['viewport'] || {})

  # The capture spec per device: viewport, and for a phone the mobile UA.
  def specs(board, scene)
    devices(scene).map do |name|
      if name == 'phone'
        ph = phone(board)
        { 'name' => 'phone', 'w' => ph['w'], 'h' => ph['h'], 'dpr' => ph['dpr'], 'mobile' => true, 'ua' => ph['ua'] }
      else
        board_viewport(board).merge('name' => 'desktop', 'mobile' => false)
      end
    end
  end

  # A scene with no devices is filmed full bleed on the board viewport, so
  # boards authored before devices existed render unchanged.
  def default?(scene) = devices(scene) == [ 'desktop' ]

  # -- validation ----------------------------------------------------------

  def board_errors(board)
    ph = board['phone']
    return [] if ph.nil?
    return [ 'phone must be an object' ] unless ph.is_a?(Hash)

    errs = []
    unknown = ph.keys - PHONE_KEYS
    errs << "phone has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    %w[w h].each { |k| errs << size_error(ph, k, Integer, SIZE, 'an integer') }
    errs << size_error(ph, 'dpr', Numeric, DPR, 'a number')
    errs << 'phone.ua must be a non-empty string' if ph.key?('ua') && ph['ua'].to_s.strip.empty?
    errs.compact
  end

  # The error for an out-of-range phone field, or nil when absent or valid.
  def size_error(spec, key, type, range, kind)
    return nil unless spec.key?(key)
    return nil if spec[key].is_a?(type) && range.cover?(spec[key])

    range_error("phone.#{key}", range, kind)
  end

  def scene_errors(scene)
    errs = []
    errs << 'device is replaced by devices and the board phone spec' if scene.key?('device')
    list = scene['devices']
    unless list.nil? || (list.is_a?(Array) && !list.empty? && (list - DEVICES).empty? && list.uniq == list)
      errs << "devices must be a non-empty list of #{DEVICES.join(', ')}"
      return errs
    end
    layout = layout_name(scene)
    errs << "layout must be one of #{LAYOUTS.join(', ')}" unless LAYOUTS.include?(layout)
    n = devices(scene).size
    errs << 'layout side_by_side needs devices ["desktop", "phone"]' if layout == 'side_by_side' && n != 2
    errs << 'two devices need layout side_by_side; film them apart as separate scenes' if layout == 'single' && n == 2
    errs
  end

  def range_error(field, range, kind) = "#{field} must be #{kind} in #{range.min}..#{range.max}"

  # -- geometry ------------------------------------------------------------

  def band_top(canvas_h) = canvas_h * (1 - PrototypeUxLint::CAPTION_BAND)

  def layout(board, scene)
    vp = board_viewport(board)
    return Layout.new(rects: [ full_bleed(vp) ], canvas_w: vp['w'], canvas_h: vp['h']) if default?(scene)

    usable_h = band_top(vp['h'])
    margin = vp['h'] * MARGIN
    ph = phone(board)
    box = Size.new(vp['w'] - (2 * margin), usable_h - (2 * margin))
    rects = if devices(scene) == [ 'phone' ]
              [ phone_rect(ph, fit_scale(box, Size.new(ph['w'], ph['h']), PHONE_BEZEL_CSS)) ]
    else
              side_by_side(vp, ph, box)
    end
    Layout.new(rects: place(rects, vp['w'], usable_h), canvas_w: vp['w'], canvas_h: vp['h'])
  end

  # Canvas px per CSS px that fits a w x h screen plus its bezel in a box.
  def fit_scale(box, size, bezel_css)
    [ box.h / (size.h + (2 * bezel_css)), box.w / (size.w + (2 * bezel_css)) ].min
  end

  def full_bleed(vp) = Rect.new(name: 'desktop', scale: 1.0, x: 0, y: 0, w: vp['w'], h: vp['h'], bezel: 0)

  def phone_rect(ph, scale)
    w = floor_even(ph['w'] * scale)
    Rect.new(name: 'phone', scale: w.to_f / ph['w'], x: 0, y: 0, w: w, h: floor_even(ph['h'] * scale), bezel: (PHONE_BEZEL_CSS * scale).round)
  end

  # The phone takes its full height in the box; the desktop shrinks to fit
  # the width left beside it.
  def side_by_side(vp, ph, box)
    phone_box = phone_rect(ph, fit_scale(box, Size.new(ph['w'], ph['h']), PHONE_BEZEL_CSS))
    room_w = box.w - (vp['w'] * GAP) - phone_box.outer_w - (2 * DESKTOP_BEZEL)
    scale = [ room_w / vp['w'], (box.h - (2 * DESKTOP_BEZEL)) / vp['h'] ].min
    w = floor_even(vp['w'] * scale)
    desktop = Rect.new(name: 'desktop', scale: w.to_f / vp['w'], x: 0, y: 0, w: w, h: floor_even(vp['h'] * scale), bezel: DESKTOP_BEZEL)
    [ desktop, phone_box ]
  end

  # Centers the row of frames horizontally and each frame vertically in the
  # space above the caption band.
  def place(rects, canvas_w, usable_h)
    gap = rects.size > 1 ? floor_even(canvas_w * GAP) : 0
    total = rects.sum(&:outer_w) + (gap * (rects.size - 1))
    left = floor_even((canvas_w - total) / 2.0)
    rects.map do |r|
      top = floor_even((usable_h - r.outer_h) / 2.0)
      placed = r.dup.tap { |p| p.x = left + r.bezel; p.y = top + r.bezel }
      left += r.outer_w + gap
      placed
    end
  end

  def floor_even(value) = (value / 2.0).floor * 2

  private_class_method :range_error, :size_error, :fit_scale, :full_bleed, :phone_rect, :side_by_side, :place, :floor_even

  # -- compositing ---------------------------------------------------------

  # The FFmpeg filter_complex that composites one input per rect (inputs in
  # rect order) into [out].
  def filter(lay)
    parts = lay.rects.each_with_index.map do |r, i|
      chain = [ "[#{i}:v]scale=#{r.w}:#{r.h}:flags=lanczos" ]
      chain << "pad=#{r.outer_w}:#{r.outer_h}:#{r.bezel}:#{r.bezel}:color=#{BEZEL}" if r.bezel.positive?
      chain << "pad=#{lay.canvas_w}:#{lay.canvas_h}:#{r.outer_x}:#{r.outer_y}:color=#{CANVAS}" if i.zero?
      "#{chain.join(',')}[d#{i}]"
    end
    (parts + overlay_chain(lay.rects)).join(';')
  end

  # Stacks every later frame onto the first, ending in [out].
  def overlay_chain(rects)
    steps = rects.each_with_index.drop(1).map do |r, i|
      "[#{i == 1 ? 'd0' : "o#{i - 1}"}][d#{i}]overlay=x=#{r.outer_x}:y=#{r.outer_y}:shortest=1[o#{i}]"
    end
    steps << "[#{rects.size > 1 ? "o#{rects.size - 1}" : 'd0'}]null[out]"
  end

  # -- cursor tracks -------------------------------------------------------

  # The arrow track for a desktop rect, mapped to the canvas.
  def arrow_path(rect, positions)
    positions.each_with_index.map do |pos, i|
      x, y = rect.map(pos['x'], pos['y'])
      track_point(i + 1, x, y, !!pos['down'])
    end
  end

  def track_point(frame, x, y, down) = { 'frame' => frame, 'x' => x.round(2), 'y' => y.round(2), 'down' => down }

  def hidden_point(frame) = track_point(frame, OFF_CANVAS, OFF_CANVAS, false)

  def hidden_path(frames) = (1..frames).map { |f| hidden_point(f) }

  # The tap track for a phone rect: the ripple sprite's top left, shown for
  # RIPPLE_FRAMES after each tap.
  def ripple_path(rect, positions)
    taps = positions.each_index.select { |i| positions[i]['down'] }
    positions.each_index.map do |i|
      tap = taps.reverse.find { |t| t <= i }
      next hidden_point(i + 1) unless tap && i - tap < RIPPLE_FRAMES

      x, y = rect.map(positions[tap]['x'], positions[tap]['y'])
      track_point(i + 1, x - (RIPPLE / 2.0), y - (RIPPLE / 2.0), i == tap)
    end
  end

  # -- lint ----------------------------------------------------------------

  # The device-frame lint compares frames within one group only.
  def group(scene, device) = "#{device} #{layout_name(scene)}"

  # caption-safe for composited frames: every frame must end above the band.
  def frame_findings(lay)
    return [] if lay.rects.size == 1 && lay.rects.first.bezel.zero?

    top = band_top(lay.canvas_h)
    lay.rects.filter_map do |r|
      next if r.bottom <= top

      { 'frame' => 0, 'rule' => 'caption-safe', 'target' => "#{r.name} frame", 'frames' => 1,
        'detail' => "#{r.name} frame bottom #{r.bottom} runs into the caption band at #{top.round}" }
    end
  end
end
