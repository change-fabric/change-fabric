# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "change_docker"
require_relative "browserless_js"

# Text measurers for the cf:diagram linter. Each answers `measured?` and
# `widths(doc) -> { text_key => [x, y, w, h] }` for a DiagramSvg::Document:
# the full box of each text in user units, anchor and lines resolved.
# Browserless asks the pinned Chromium for getBBox of every <text>; Static is
# the browser-free estimate used with --no-measure.
module DiagramMeasure
  # Raised when measurement needs Docker and Docker or browserless is not there.
  class Unavailable < StandardError; end

  # Raised when one measurement request would exceed browserless's body cap.
  class TooLarge < StandardError; end

  # Conservative box estimate with no browser: 0.6 em per Latin char and
  # 1.0 em per CJK char, 1.2 em per line, x placed by anchor, top at
  # 0.8 em above each baseline, unioned across lines. Advisory only, so
  # `measured?` is false.
  class Static
    CJK = /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/

    def measured? = false

    def widths(doc) = doc.texts.to_h { |t| [ t.key, box_for(t) ] }

    def widths_for(text) = text.lines.map { |l| line_width(l.text, text.font_size) }.max || 0.0

    def box_for(text)
      size = text.font_size
      boxes = text.lines.map do |l|
        w = line_width(l.text, size)
        left = { "start" => l.x, "end" => l.x - w }.fetch(text.anchor, l.x - (w / 2.0))
        DiagramSvg::Box.new(x: left, y: l.y - (0.8 * size), w: w, h: 1.2 * size)
      end
      b = boxes.reduce { |acc, x| acc.union(x) }
      [ b.x, b.y, b.w, b.h ]
    end

    def line_width(str, size) = str.each_char.sum { |c| c.match?(CJK) ? 1.0 : 0.6 } * size
  end

  # Measures text with getBBox inside one browserless session per lint run.
  # Results are cached on disk by SHA-256 of the SVG bytes and the pinned
  # image, so a cache hit never touches Docker. No screenshot is taken.
  class Browserless
    MAX_BODY_BYTES = 10 * 1024 * 1024
    DEFAULT_CACHE = File.join(Dir.home, ".cache", "cf", "diagram-measure")
    # Bumped when the cached value shape changes; v2 stores [x, y, w, h].
    CACHE_VERSION = 3

    # `browser` yields a session that answers run_function(js); the default
    # starts the pinned container. `available` is checked before any start.
    def initialize(cache_dir: DEFAULT_CACHE, browser: nil, available: -> { ChangeDocker.available? })
      @cache_dir = cache_dir
      @browser = browser || ->(&blk) { ChangeDocker.with_browserless(network: nil, &blk) }
      @available = available
      @static = Static.new
    end

    def measured? = true

    def self.key(svg) = Digest::SHA256.hexdigest("v#{CACHE_VERSION}\n#{ChangeDocker::BROWSERLESS_IMAGE}\n#{svg}")

    # Measures every cache miss among docs in one shared container, so a lint
    # run starts at most one browserless and an all-hit run starts none.
    def prefetch(docs)
      misses = docs.reject { |d| read_cache(self.class.key(d.source)) }.uniq(&:source)
      return if misses.empty?

      with_session { |session| misses.each { |d| write_cache(self.class.key(d.source), measure(session, d)) } }
    end

    def widths(doc)
      key = self.class.key(doc.source)
      cached = read_cache(key)
      return cached if cached

      result = with_session { |session| measure(session, doc) }
      write_cache(key, result)
      result
    end

    def js_module(svg)
      html = "<!doctype html><html><body style=\"margin:0\">#{svg}</body></html>"
      mod = <<~JS
        export default async ({ page }) => {
          #{BrowserlessJs.inline_html_js(html)}
          const data = await page.evaluate(() => {
            const out = {};
            document.querySelectorAll("text").forEach((el, i) => {
              el.getComputedTextLength();
              const b = el.getBBox();
              out[el.id || ("text[" + i + "]")] = { x: b.x, y: b.y, w: b.width, h: b.height };
            });
            return out;
          });
          return { data, type: "application/json" };
        };
      JS
      raise TooLarge, "measure request is #{mod.bytesize} bytes, over the #{MAX_BODY_BYTES} byte cap" if mod.bytesize > MAX_BODY_BYTES

      mod
    end

    private

    def with_session(&)
      raise Unavailable, "docker is not available" unless @available.call

      result = nil
      @browser.call { |session| result = yield(session) }
      result
    rescue Unavailable, TooLarge
      raise
    rescue StandardError => e
      raise Unavailable, "browserless failed: #{e.message}"
    end

    def measure(session, doc)
      raw = session.run_function(js_module(doc.source))
      doc.texts.to_h do |t|
        estimate = @static.box_for(t)
        got = raw[t.key]
        box = got.is_a?(Hash) ? %w[x y w h].map { |k| got[k].to_f } : nil
        box = estimate if box.nil? || box[2] <= 0 && !t.content.strip.empty?
        box = union(box, estimate) if t.content.match?(Static::CJK)
        [ t.key, box ]
      end
    end

    def union(a, b)
      x = [ a[0], b[0] ].min
      y = [ a[1], b[1] ].min
      [ x, y, [ a[0] + a[2], b[0] + b[2] ].max - x, [ a[1] + a[3], b[1] + b[3] ].max - y ]
    end

    def cache_path(key) = File.join(@cache_dir, "#{key}.json")

    def read_cache(key)
      path = cache_path(key)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      valid = data.is_a?(Hash) && data.values.all? { |v| v.is_a?(Array) && v.size == 4 && v.all?(Numeric) }
      valid ? data : nil
    rescue JSON::ParserError
      nil
    end

    def write_cache(key, result)
      FileUtils.mkdir_p(@cache_dir)
      File.write(cache_path(key), JSON.generate(result))
    rescue SystemCallError
      nil
    end
  end
end
