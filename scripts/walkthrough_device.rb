# frozen_string_literal: true

require_relative 'ffmpeg_square'
require_relative 'prototype_capture'
require_relative 'prototype_ux_lint'
require_relative 'walkthrough_browser_frame'
require_relative 'walkthrough_sharpness'

# Which devices a live or compose scene is filmed on, and where each lands
# on the board canvas. `devices` is ["desktop"] (the default, the board
# viewport, full bleed as before), ["phone"], or ["desktop", "phone"];
# `layout` is single or side_by_side (both devices in one shot). A phone is
# captured at the board's `phone` spec under mobile emulation, scaled to fit
# above the caption band inside a simple bezel on a neutral canvas.
#
# `"device": "phone-fullbleed"` films the phone frameless instead: captured
# at the board's `phone_fullbleed` CSS viewport (default 390 wide, height
# from the canvas aspect) at the dpr that fills the canvas, scaled edge to
# edge with no bezel, mat, or band, and a subtle scrim under the captions.
module WalkthroughDevice
  DEVICES = %w[desktop phone].freeze
  LAYOUTS = %w[single side_by_side].freeze
  PHONE_KEYS = %w[w h dpr ua].freeze
  SIZE = (100..4000)
  DPR = (1..4)
  DEFAULT_UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) ' \
               'Chrome/130.0.0.0 Mobile Safari/537.36'
  DEFAULT_PHONE = { 'w' => 390, 'h' => 844, 'dpr' => 2, 'ua' => DEFAULT_UA }.freeze
  FULLBLEED = 'phone-fullbleed'
  FULLBLEED_KEYS = %w[w h].freeze
  FULLBLEED_W = 390
  ASPECT_SLACK = 0.01
  # The caption scrim: SCRIM_STEPS stacked bands of the bezel ink, each
  # SCRIM_ALPHA, ramping darker toward the bottom over SCRIM of the height.
  SCRIM = 0.24
  SCRIM_STEPS = 4
  SCRIM_ALPHA = 0.12
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

  Layout = Struct.new(:rects, :canvas_w, :canvas_h, :scrim, keyword_init: true) do
    def rect(name) = rects.find { |r| r.name == name }
  end

  module_function

  def fullbleed?(scene) = scene['device'] == FULLBLEED

  def devices(scene)
    return [ 'phone' ] if fullbleed?(scene)

    Array(scene['devices']).empty? ? [ 'desktop' ] : scene['devices']
  end

  def layout_name(scene) = fullbleed?(scene) ? 'fullbleed' : (scene['layout'] || 'single')

  # The full-bleed phone's CSS viewport: `phone_fullbleed.w` (default 390),
  # and `h` or else the canvas aspect at that width (693 on 1080x1920).
  def fullbleed_viewport(board)
    vp = board_viewport(board)
    own = board['phone_fullbleed'] || {}
    w = own['w'] || FULLBLEED_W
    { 'w' => w, 'h' => own['h'] || (w * vp['h'].to_f / vp['w']).round }
  end

  # Device px per CSS px that fills the scene's stage width exactly.
  def fullbleed_dpr(board, scene)
    stage_w = WalkthroughSharpness.stage_size(board, scene).first
    (stage_w.to_f / fullbleed_viewport(board)['w']).round(4).clamp(DPR.min, DPR.max)
  end

  # How much the cursor and tap sprites grow: canvas px per CSS px for a
  # full-bleed phone, 1.0 (unchanged) for every other layout.
  def sprite_scale(board, scene)
    return 1.0 unless fullbleed?(scene)

    layout(board, scene).rect('phone').scale.round(4)
  end

  def phone(board) = DEFAULT_PHONE.merge(board['phone'] || {})

  def board_viewport(board) = PrototypeCapture::DEFAULT_VIEWPORT.merge(board['viewport'] || {})

  # The capture spec per device: viewport, and for a phone the mobile UA.
  # Every device of a scene shares one dpr, the largest any of them needs:
  # it is also the scale the browser is launched at (capture_scale), and a
  # device emulated below it would screencast at its own dpr while its
  # first screenshot came back at the launch scale.
  def specs(board, scene)
    raw = devices(scene).map do |name|
      if name == 'phone' && fullbleed?(scene)
        fullbleed_viewport(board).merge('name' => 'phone', 'dpr' => fullbleed_dpr(board, scene), 'mobile' => true, 'ua' => phone(board)['ua'])
      elsif name == 'phone'
        ph = phone(board)
        { 'name' => 'phone', 'w' => ph['w'], 'h' => ph['h'], 'dpr' => WalkthroughSharpness.phone_dpr(board, scene, ph), 'mobile' => true,
          'ua' => ph['ua'] }
      else
        board_viewport(board).merge('name' => 'desktop', 'mobile' => false, 'dpr' => desktop_dpr(board, scene))
      end
    end
    scale = capture_scale(raw)
    raw.map { |s| s.merge('dpr' => scale) }
  end

  # A storyboard's own viewport dpr always wins. Otherwise capture enough
  # device pixels to fill the desktop's slot on the scene's stage (the
  # canvas times any camera zoom, inside any browser frame), so assembly
  # never upsamples small text. See WalkthroughSharpness.
  def desktop_dpr(board, scene) = WalkthroughSharpness.desktop_dpr(board, scene)

  # The scale factor the browser is launched at for a scene: the largest
  # dpr any of its devices captures at. Headless Chromium's screencast and
  # raw CDP screenshots ignore the emulated dpr and stay at CSS px unless
  # the browser itself runs at that scale.
  def capture_scale(specs) = specs.map { |s| s['dpr'] }.max

  # A scene with no devices is filmed full bleed on the board viewport, so
  # boards authored before devices existed render unchanged.
  def default?(scene) = devices(scene) == [ 'desktop' ]

  # -- validation ----------------------------------------------------------

  def board_errors(board) = phone_errors(board) + fullbleed_errors(board)

  def fullbleed_errors(board)
    fb = board['phone_fullbleed']
    return [] if fb.nil?
    return [ 'phone_fullbleed must be an object' ] unless fb.is_a?(Hash)

    unknown = fb.keys - FULLBLEED_KEYS
    errs = unknown.empty? ? [] : [ "phone_fullbleed has unknown keys: #{unknown.join(', ')}" ]
    sizes = FULLBLEED_KEYS.filter_map do |k|
      next if !fb.key?(k) || (fb[k].is_a?(Integer) && SIZE.cover?(fb[k]))

      range_error("phone_fullbleed.#{k}", SIZE, 'an integer')
    end
    errs + sizes + (sizes.empty? ? aspect_errors(board) : [])
  end

  # The capture is scaled to the canvas on both axes and taps map by one
  # scale, so h must keep the canvas aspect at w (within ASPECT_SLACK).
  def aspect_errors(board)
    return [] unless board.dig('phone_fullbleed', 'h')

    vp = board_viewport(board)
    fit = fullbleed_viewport(board)
    want = fit['w'] * vp['h'].to_f / vp['w']
    return [] if (fit['h'] - want).abs <= want * ASPECT_SLACK

    [ "phone_fullbleed.h must keep the canvas aspect: #{want.round} at w #{fit['w']}" ]
  end

  def phone_errors(board)
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
    if scene.key?('device')
      return [ 'device is replaced by devices and the board phone spec' ] unless fullbleed?(scene)
      return [] unless scene.key?('devices') || scene.key?('layout')

      return [ "device #{FULLBLEED} takes no devices or layout" ]
    end
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
    return fullbleed_layout(board, vp) if fullbleed?(scene)

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

  # The phone fills the whole canvas: scale is canvas px per CSS px.
  def fullbleed_layout(board, vp)
    rect = Rect.new(name: 'phone', scale: vp['w'].to_f / fullbleed_viewport(board)['w'], x: 0, y: 0, w: vp['w'], h: vp['h'], bezel: 0)
    Layout.new(rects: [ rect ], canvas_w: vp['w'], canvas_h: vp['h'], scrim: true)
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

  private_class_method :aspect_errors, :range_error, :size_error, :fit_scale, :full_bleed, :phone_rect, :side_by_side, :place, :floor_even, :fullbleed_layout

  # -- compositing ---------------------------------------------------------

  # The FFmpeg filter_complex that composites one input per rect (inputs in
  # rect order) into [out].
  def filter(lay)
    parts = lay.rects.each_with_index.map do |r, i|
      chain = [ "[#{i}:v]#{FfmpegSquare.scale(r.w, r.h)}" ]
      chain << "pad=#{r.outer_w}:#{r.outer_h}:#{r.bezel}:#{r.bezel}:color=#{BEZEL}" if r.bezel.positive?
      chain << "pad=#{lay.canvas_w}:#{lay.canvas_h}:#{r.outer_x}:#{r.outer_y}:color=#{CANVAS}" if i.zero?
      "#{chain.join(',')}[d#{i}]"
    end
    chain = overlay_chain(lay.rects)
    chain[-1] = "[d0]#{scrim_filter}[out]" if lay.scrim
    (parts + chain).join(';')
  end

  # The caption scrim: stacked drawbox bands of the bezel ink over the
  # bottom SCRIM of the frame, so burned or overlaid captions read on any
  # screen without a reserved band.
  def scrim_filter
    (0...SCRIM_STEPS).map do |k|
      top = format('%.4f', 1 - (SCRIM * (SCRIM_STEPS - k) / SCRIM_STEPS))
      "drawbox=x=0:y=ih*#{top}:w=iw:h=ih:color=#{BEZEL}@#{SCRIM_ALPHA}:t=fill"
    end.join(',')
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
  def ripple_path(rect, positions, size = RIPPLE)
    taps = positions.each_index.select { |i| positions[i]['down'] }
    positions.each_index.map do |i|
      tap = taps.reverse.find { |t| t <= i }
      next hidden_point(i + 1) unless tap && i - tap < RIPPLE_FRAMES

      x, y = rect.map(positions[tap]['x'], positions[tap]['y'])
      track_point(i + 1, x - (size / 2.0), y - (size / 2.0), i == tap)
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
