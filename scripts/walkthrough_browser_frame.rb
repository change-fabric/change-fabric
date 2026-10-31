# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'
require_relative 'prototype_ux_lint'

# The browser frame: `screen.frame: "browser"` on a live or environment
# scene films the captured viewport inside a neutral, unbranded browser
# window (a tab with the scene's title, an address bar with its address)
# on the desktop canvas, scaled to fit above the caption band. Modeled on
# the phone bezel compositor in walkthrough_device.rb: pure geometry here,
# one FFmpeg filter, offline in the pinned container.
module WalkthroughBrowserFrame
  FRAMES = %w[browser].freeze
  SCREEN_KEYS = %w[frame title address].freeze
  # Bumped when the chrome drawn by the filter changes; it is key material.
  VERSION = 1
  MAX_TEXT = 200
  MARGIN = 0.04
  # Chrome heights as a share of the canvas height.
  TAB_SHARE = 0.036
  BAR_SHARE = 0.042
  BORDER = 2
  CANVAS = '0xD9DBE0'
  BORDER_COLOR = '0x9A9DA6'
  STRIP = '0xE4E6EA'
  TOOLBAR = '0xF6F7F9'
  FIELD = '0xFFFFFF'
  CONTROL = '0xB4B7BF'
  TEXT = '0x2B2D33'
  # Average glyph width as a share of the font size, for truncation.
  GLYPH = 0.56

  Rect = Struct.new(:name, :scale, :x, :y, :w, :h, :bezel, keyword_init: true) do
    def outer_x = x - bezel
    def outer_y = y - bezel
    def outer_w = w + (2 * bezel)
    def outer_h = h + (2 * bezel)
    def bottom = outer_y + outer_h
    def map(px, py) = [ x + (px * scale), y + (py * scale) ]
  end

  Box = Struct.new(:x, :y, :w, :h)

  # `rects` holds the one content rect (named desktop, so the arrow track
  # maps through it); `window`, `tab`, `bar`, `field` are the chrome boxes.
  Layout = Struct.new(:rects, :canvas_w, :canvas_h, :window, :tab, :bar, :field, :font, keyword_init: true) do
    def rect(name) = rects.find { |r| r.name == name }
    def content = rects.first
  end

  module_function

  def frame(scene) = scene.dig('screen', 'frame')

  def browser?(scene) = scene['screen'].is_a?(Hash) && frame(scene) == 'browser'

  def live?(scene) = scene['screen'].is_a?(Hash) && scene['screen'].key?('url')

  # The address bar text: authored, else a live scene's URL.
  def address(scene) = (scene.dig('screen', 'address') || scene.dig('screen', 'url')).to_s

  # The tab title: authored, else the address host.
  def title(scene)
    authored = scene.dig('screen', 'title')
    return authored.to_s if authored

    address(scene)[%r{\A(?:[a-z]+://)?([^/\s]+)}i, 1].to_s
  end

  # -- validation ----------------------------------------------------------

  def errors(scene)
    screen = scene['screen'].is_a?(Hash) ? scene['screen'] : {}
    framed = screen.key?('frame')
    return [] unless framed || screen.key?('title') || screen.key?('address')
    return [ 'screen.title and screen.address need screen.frame "browser"' ] unless framed

    errs = []
    errs << "screen.frame must be one of #{FRAMES.join(', ')}" unless FRAMES.include?(screen['frame'])
    errs << 'screen.frame "browser" applies to a live or environment scene' unless live?(scene) || scene['kind'] == 'environment'
    errs << 'screen.frame "browser" films the desktop only; drop devices and layout' unless Array(scene['devices']).reject { |d| d == 'desktop' }.empty? && scene['layout'].nil?
    %w[title address].each { |k| errs << text_error(screen, k) }
    errs << 'an environment scene in a browser frame needs screen.address' if scene['kind'] == 'environment' && address(scene).strip.empty?
    errs.compact
  end

  def text_error(screen, key)
    return nil unless screen.key?(key)

    value = screen[key]
    return nil if value.is_a?(String) && !value.strip.empty? && value.size <= MAX_TEXT && !value.match?(/[[:cntrl:]]/)

    "screen.#{key} must be a single-line string of 1..#{MAX_TEXT} characters"
  end

  # The frame's part of a scene's frames_key, or nil for an unframed scene.
  def material(scene)
    return nil unless browser?(scene)

    { frame: 'browser', title: title(scene), address: address(scene), version: VERSION,
      ffmpeg: ChangeDocker::FFMPEG_IMAGE.split('@').last }
  end

  # -- geometry ------------------------------------------------------------

  def viewport(board) = { 'w' => 1920, 'h' => 1080 }.merge(board['viewport'] || {})

  def band_top(canvas_h) = canvas_h * (1 - PrototypeUxLint::CAPTION_BAND)

  def floor_even(value) = (value / 2.0).floor * 2

  # The window centered above the caption band, its content keeping the
  # viewport's aspect ratio.
  def layout(board)
    vp = viewport(board)
    cw, ch = vp['w'], vp['h']
    tab_h = floor_even(ch * TAB_SHARE)
    bar_h = floor_even(ch * BAR_SHARE)
    margin = ch * MARGIN
    room_w = cw - (2 * margin) - (2 * BORDER)
    room_h = band_top(ch) - (2 * margin) - (2 * BORDER) - tab_h - bar_h
    scale = [ room_w / cw, room_h / ch ].min
    w = floor_even(cw * scale)
    h = floor_even(ch * scale)
    outer_w = w + (2 * BORDER)
    outer_h = h + (2 * BORDER) + tab_h + bar_h
    left = floor_even((cw - outer_w) / 2.0)
    top = floor_even((band_top(ch) - outer_h) / 2.0)
    content = Rect.new(name: 'desktop', scale: w.to_f / cw, x: left + BORDER, y: top + BORDER + tab_h + bar_h, w: w, h: h, bezel: 0)
    inset = (bar_h * 0.18).round
    nav_w = bar_h * 3
    Layout.new(rects: [ content ], canvas_w: cw, canvas_h: ch,
               window: Box.new(left, top, outer_w, outer_h),
               tab: Box.new(left + BORDER + inset, top + BORDER + inset, [ (w * 0.24).round, 160 ].max, tab_h - inset),
               bar: Box.new(left + BORDER, top + BORDER + tab_h, w, bar_h),
               field: Box.new(left + BORDER + nav_w, top + BORDER + tab_h + inset, w - nav_w - inset, bar_h - (2 * inset)),
               font: [ (tab_h * 0.42).round, 10 ].max)
  end

  # Text clipped to what fits `width` canvas px at the layout font size.
  def fit(text, width, font)
    max = [ (width / (font * GLYPH)).floor, 4 ].max
    text.size <= max ? text : "#{text[0, max - 3]}..."
  end

  # -- compositing ---------------------------------------------------------

  def box(b, color) = "drawbox=x=#{b.x}:y=#{b.y}:w=#{b.w}:h=#{b.h}:color=#{color}:t=fill"

  # Text is read from files so no title or address needs filter escaping.
  def text(path, x, y, font) = "drawtext=textfile='#{path}':expansion=none:font=Sans:fontsize=#{font}:fontcolor=#{TEXT}:x=#{x}:y=#{y}"

  # The FFmpeg filter_complex for input 0 (the captured viewport) into
  # [out]. `title_file` and `address_file` are container paths.
  def filter(lay, title_file:, address_file:)
    c = lay.content
    win, tab, bar, field = lay.window, lay.tab, lay.bar, lay.field
    dot = (bar.h * 0.34).round
    controls = (0..2).map { |i| box(Box.new(bar.x + (bar.h * 0.33).round + (i * bar.h * 0.9).round, bar.y + ((bar.h - dot) / 2), dot, dot), CONTROL) }
    chain = [
      "[0:v]scale=#{c.w}:#{c.h}:flags=lanczos,setsar=1",
      "pad=#{lay.canvas_w}:#{lay.canvas_h}:#{c.x}:#{c.y}:color=#{CANVAS}",
      "drawbox=x=#{win.x}:y=#{win.y}:w=#{win.w}:h=#{win.h}:color=#{BORDER_COLOR}:t=#{BORDER}",
      box(Box.new(win.x + BORDER, win.y + BORDER, win.w - (2 * BORDER), tab.y + tab.h - win.y - BORDER), STRIP),
      box(tab, TOOLBAR),
      box(bar, TOOLBAR),
      *controls,
      box(field, FIELD),
      text(title_file, tab.x + (lay.font * 0.8).round, "#{tab.y}+(#{tab.h}-th)/2", lay.font),
      text(address_file, field.x + (lay.font * 0.7).round, "#{field.y}+(#{field.h}-th)/2", lay.font)
    ]
    "#{chain.join(',')}[out]"
  end

  # Writes the clipped tab and address text beside the frames; returns the
  # two host paths.
  def write_text(lay, scene, dir)
    FileUtils.mkdir_p(dir)
    title_path = File.join(dir, 'title.txt')
    address_path = File.join(dir, 'address.txt')
    File.write(title_path, fit(title(scene), lay.tab.w - (lay.font * 1.6), lay.font))
    File.write(address_path, fit(address(scene), lay.field.w - (lay.font * 1.4), lay.font))
    [ title_path, address_path ]
  end

  # The cursor track mapped from viewport px into the framed canvas.
  def map_cursor(lay, points)
    points.map do |pt|
      x, y = lay.content.map(pt['x'], pt['y'])
      pt.merge('x' => x.round(2), 'y' => y.round(2))
    end
  end

  class FrameError < StandardError; end

  # Frames an already captured prototype scene directory in place: every
  # NNNNNN.png and cursor.json. `work` is mounted at /work and must hold
  # `dir`. On failure the end-state.json marker is removed, so the scene
  # is not treated as captured.
  def frame_dir!(board, scene, dir, work:, docker: ->(argv) { Open3.capture2e(*argv) })
    lay = layout(board)
    tmp = File.join(dir, 'framed')
    FileUtils.rm_rf(tmp)
    title_path, address_path = write_text(lay, scene, File.join(tmp, 'chrome'))
    cpath = ->(p) { File.join('/work', File.expand_path(p).delete_prefix("#{File.expand_path(work)}/")) }
    args = [ '-hide_banner', '-nostdin', '-y', '-start_number', '1', '-i', File.join(cpath.(dir), '%06d.png'),
             '-filter_complex', filter(lay, title_file: cpath.(title_path), address_file: cpath.(address_path)),
             '-map', '[out]', '-start_number', '1', File.join(cpath.(tmp), '%06d.png') ]
    argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, args: args, mounts: { File.expand_path(work) => '/work' },
                                    workdir: '/work')
    out, status = docker.call(argv)
    unless status.success?
      FileUtils.rm_f(File.join(dir, 'end-state.json'))
      raise FrameError, "#{scene['id']}: ffmpeg browser frame failed:\n#{out.to_s.lines.last(10).join}"
    end
    Dir.glob(File.join(tmp, '[0-9]*.png')).each { |f| FileUtils.mv(f, File.join(dir, File.basename(f))) }
    cursor = File.join(dir, 'cursor.json')
    File.write(cursor, JSON.pretty_generate(map_cursor(lay, JSON.parse(File.read(cursor))))) if File.file?(cursor)
    FileUtils.rm_rf(tmp)
    dir
  end
end
