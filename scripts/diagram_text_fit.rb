# frozen_string_literal: true

# One text-width estimate for the diagram lane layer, shared by the spec
# validator (here) and the lane layer (cf_diagram_lanes.js mirrors `width`,
# `lines`, EM and FIT, and a unit test holds the two together). It works at
# the font size a box is actually drawn in. Each character takes the em
# share of its class, set at or above the widest glyph of that class in the
# pinned browserless Chromium's system-ui at weight 600 (the lane text
# weight): a flat 0.6 em, DiagramMeasure::Static's share, under-reads that
# face by about a tenth on ordinary words and by half on m or W. Diagrams
# are sized from the spec this way and never measured at render time; the
# capture tests measure the rendered boxes and fail on overflow.
module DiagramTextFit
  CJK = /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/
  # Classes of Latin glyphs and their em share; anything else Latin takes
  # `default`, and a CJK character takes `cjk`.
  EM = {
    'narrow' => { 'chars' => " 'ijlIJ|/.,;:f-!()[]tr_`", 'em' => 0.5 },
    'caps' => { 'chars' => 'BRXAVKUGDNHQO^>=<+~#&', 'em' => 0.88 },
    'wide' => { 'chars' => 'wMm@%W', 'em' => 1.11 },
    'default' => 0.74,
    'cjk' => 1.0
  }.freeze

  # Every text box the lane layer draws: the font px it renders at, the
  # widest its text may run without an icon, what an icon takes from that,
  # and how many lines it may use. `aside` is a second text sharing the line
  # (a report row's lane name, the report head's count badge) at its own
  # font, plus the fixed room around it. Over budget is a validator error;
  # nothing is ever cut off. The lane layer keeps this exact table as FIT.
  FIT = {
    'checkpoint' => { 'font' => 19, 'width' => 196, 'icon' => 28, 'lines' => 2, 'line_h' => 23, 'pad_y' => 6 },
    'token' => { 'font' => 17, 'width' => 196, 'icon' => 22, 'lines' => 1 },
    'lane_label' => { 'font' => 22, 'width' => 248, 'icon' => 30, 'lines' => 1 },
    'report_row' => { 'font' => 18, 'width' => 328, 'icon' => 0, 'lines' => 1, 'aside_font' => 15, 'aside_pad' => 0 },
    'report_head' => { 'font' => 22, 'width' => 390, 'icon' => 0, 'lines' => 1, 'aside_font' => 16, 'aside_pad' => 32 }
  }.freeze

  module_function

  # Estimated px width of `text` drawn at `font_px`.
  def width(text, font_px) = text.to_s.each_char.sum { |c| em(c) } * font_px

  def em(char)
    return EM['cjk'] if char.match?(CJK)

    klass = %w[narrow caps wide].find { |k| EM[k]['chars'].include?(char) }
    klass ? EM[klass]['em'] : EM['default']
  end

  # `text` wrapped greedily at spaces into lines no wider than `max_w`; a
  # word wider than a whole line breaks between characters, as the browser
  # does under `overflow-wrap: anywhere`.
  def lines(text, font_px, max_w)
    out = []
    cur = ''
    text.to_s.split(' ').each do |word|
      trial = cur.empty? ? word : "#{cur} #{word}"
      if width(trial, font_px) <= max_w
        cur = trial
        next
      end

      out << cur unless cur.empty?
      cur = ''
      word.each_char do |c|
        if !cur.empty? && width(cur + c, font_px) > max_w
          out << cur
          cur = ''
        end
        cur += c
      end
    end
    out << cur unless cur.empty?
    out
  end

  # The room a box leaves for its text: its width, less an icon's share.
  def room(box, icon: false) = FIT.fetch(box)['width'] - (icon ? FIT.fetch(box)['icon'] : 0)

  # Roughly how many ordinary Latin characters fit `px` at `font_px`, for
  # messages.
  def chars(px, font_px) = (px / (EM['default'] * font_px)).floor
end
