# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require_relative 'change_docker'
require_relative 'design_config'
require_relative 'diagram_palette'
require_relative 'prototype_capture'
require_relative 'prototype_imagegen'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_env'

# cf:image heavy text mode: gpt-image-2 paints a textless plate per aspect
# family (at most two paid calls), then each output size is cropped from its
# family's plate and real copy is laid over it as HTML rendered in the pinned
# browserless container. The imagegen, the browser, and the Docker probe are
# injected so the tests need neither network nor Docker.
module ImagePlate
  IMAGE_PLATE_VERSION = 1
  FAMILY_SIZE = { landscape: '1536x1024', portrait: '1024x1536' }.freeze
  FAMILY_DIMS = FAMILY_SIZE.transform_values { |s| s.split('x').map(&:to_i) }.freeze
  DEFAULT_OUT = 'image-text'
  # The cf:diagram default skin (light), used when the repo has no tokens file.
  FALLBACK_COLORS = { '--bg' => '#F5F5F5', '--ink' => '#2D3142', '--muted' => '#4F5D75', '--accent' => '#B5401C',
                      '--surface' => '#FFFFFF' }.freeze
  FALLBACK_FONT = 'system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif'

  class SpecError < StandardError; end
  class OverflowError < StandardError; end
  class Unavailable < StandardError; end
  class CeilingError < StandardError; end

  Zone = Data.define(:x, :y, :w, :h)
  Size = Data.define(:name, :width, :height, :zone) do
    def family = width >= height ? :landscape : :portrait
  end

  # The parsed, validated copy spec. Unknown keys are ignored; the digest is
  # over the canonical JSON so reformatting the file never busts the cache.
  class Spec
    attr_reader :copy, :sizes, :focal, :digest

    def self.load(path)
      raise SpecError, "cannot read spec #{path}" unless File.file?(path)

      parse(File.read(path))
    end

    def self.parse(text)
      data = JSON.parse(text)
      raise SpecError, 'spec must be a JSON object' unless data.is_a?(Hash)

      new(data)
    rescue JSON::ParserError => e
      raise SpecError, "spec is not valid JSON: #{e.message}"
    end

    def initialize(data)
      @copy = parse_copy(data['copy'])
      @sizes = parse_sizes(data['sizes'])
      @focal = parse_focal(data['focal'])
      @digest = WalkthroughCache.key({ copy: @copy, sizes: @sizes.map(&:to_h).map { |s| s.merge(zone: s[:zone].to_h) },
                                       focal: @focal })
    end

    def families = sizes.map(&:family).uniq.sort_by { |f| FAMILY_SIZE.keys.index(f) }

    private

    def parse_copy(copy)
      raise SpecError, 'spec copy must be an object' unless copy.is_a?(Hash)

      headline = copy['headline']
      raise SpecError, 'spec copy.headline must be a non-empty string' unless headline.is_a?(String) && !headline.strip.empty?

      out = { 'headline' => headline }
      %w[body cta].each do |k|
        next if copy[k].nil?
        raise SpecError, "spec copy.#{k} must be a string" unless copy[k].is_a?(String)

        out[k] = copy[k]
      end
      out
    end

    def parse_sizes(sizes)
      raise SpecError, 'spec sizes must be a non-empty array' unless sizes.is_a?(Array) && !sizes.empty?

      parsed = sizes.each_with_index.map { |s, i| parse_size(s, i) }
      dup = parsed.map(&:name).tally.find { |_, n| n > 1 }
      raise SpecError, "spec size name #{dup.first} is not unique" if dup

      parsed
    end

    def parse_size(size, index)
      raise SpecError, "spec sizes[#{index}] must be an object" unless size.is_a?(Hash)

      name = size['name']
      raise SpecError, "spec sizes[#{index}].name must be a non-empty string" unless name.is_a?(String) && !name.empty?

      %w[width height].each do |k|
        raise SpecError, "spec size #{name} #{k} must be a positive integer" unless size[k].is_a?(Integer) && size[k].positive?
      end
      Size.new(name: name, width: size['width'], height: size['height'], zone: parse_zone(size['zone'], name))
    end

    def parse_zone(zone, name)
      raise SpecError, "spec size #{name} zone must be an object" unless zone.is_a?(Hash)

      vals = %w[x y w h].to_h { |k| [ k, zone[k] ] }
      unless vals.values.all? { |v| v.is_a?(Numeric) && v.between?(0, 1) }
        raise SpecError, "spec size #{name} zone x, y, w, h must be numbers in 0..1"
      end
      raise SpecError, "spec size #{name} zone is out of range (x+w and y+h must be <= 1)" if vals['x'] + vals['w'] > 1 + 1e-9 || vals['y'] + vals['h'] > 1 + 1e-9

      Zone.new(x: vals['x'], y: vals['y'], w: vals['w'], h: vals['h'])
    end

    def parse_focal(focal)
      return { 'x' => 0.5, 'y' => 0.5 } if focal.nil?

      ok = focal.is_a?(Hash) && %w[x y].all? { |k| focal[k].is_a?(Numeric) && focal[k].between?(0, 1) }
      raise SpecError, 'spec focal x and y must be numbers in 0..1' unless ok

      { 'x' => focal['x'], 'y' => focal['y'] }
    end
  end

  # One heavy-mode run: plates, overlay, crop. Returns the written paths.
  class Run
    attr_reader :spec, :prompt

    def initialize(spec:, prompt:, quality: PrototypeImagegen::QUALITY_DRAFT, cache: '.cache', out_dir: DEFAULT_OUT, repo: Dir.pwd,
                   imagegen: PrototypeImagegen, http: nil, browser: nil, available: -> { ChangeDocker.available? },
                   version: IMAGE_PLATE_VERSION)
      @spec = spec
      @prompt = prompt
      @quality = quality
      @cache = cache
      @out_dir = out_dir
      @repo = repo
      @imagegen = imagegen
      @http = http
      @browser = browser || ->(&blk) { ChangeDocker.with_browserless(network: nil, &blk) }
      @available = available
      @version = version
    end

    def families = spec.families

    # The plate prompt for one family: the user's prompt plus the calm zone.
    def plate_prompt(family)
      "#{prompt}\n\nNo text, letters, logos, or watermarks; keep the #{zone_description(family)} region calm " \
        'and uncluttered for overlaid copy.'
    end

    # The union of a family's size zones, mapped through each size's cover
    # crop onto plate coordinates (0..1).
    def plate_zone(family)
      rects = spec.sizes.select { |s| s.family == family }.map { |s| zone_on_plate(s, family) }
      x0 = rects.map { |r| r[0] }.min
      y0 = rects.map { |r| r[1] }.min
      x1 = rects.map { |r| r[2] }.max
      y1 = rects.map { |r| r[3] }.max
      [ x0, y0, x1, y1 ]
    end

    # Plate keys need no generated file: the second plate's key folds in the
    # first plate's key, which stands for the ref it will carry.
    def plate_keys
      first = nil
      families.to_h do |family|
        inputs = { prompt: plate_prompt(family), size: FAMILY_SIZE[family], quality: @quality, model: PrototypeImagegen::MODEL }
        inputs[:ref] = first if first
        key = WalkthroughCache.key(inputs)
        first ||= key
        [ family, key ]
      end
    end

    def composite_key
      inputs = { plates: plate_keys.values, spec: spec.digest, tokens: tokens_digest, plate_version: @version }
      digest = browserless_digest
      inputs[:browserless] = digest if digest
      WalkthroughCache.key(inputs)
    end

    def size_key(size) = WalkthroughCache.key({ composite: composite_key, size: size.name })

    def image_path(size) = WalkthroughCache.path(@cache, :images, size_key(size), 'png')

    def cached? = spec.sizes.all? { |s| File.file?(image_path(s)) }

    # The estimate: plates not yet cached times the per-image price.
    def estimate_usd
      return 0.0 if cached?

      paid = 0
      refs = []
      plate_requests.each do |req|
        path = plate_path(req, refs)
        paid += 1 unless path && File.file?(path)
        refs = [ path ] if refs.empty?
      end
      (paid * PrototypeImagegen::PRICE.fetch(@quality)).round(2)
    end

    def call
      unless cached?
        raise Unavailable, 'Docker is not available' unless @available.call

        plates = generate_plates
        shots = render(plates)
        spec.sizes.each do |s|
          WalkthroughCache.fetch(@cache, :images, size_key(s), 'png') { |tmp| File.binwrite(tmp, shots.fetch(s.name)) }
        end
      end
      write_out
    end

    private

    def html_for(size, plate_path)
      fx = (spec.focal['x'] * 100).round(2)
      fy = (spec.focal['y'] * 100).round(2)
      z = size.zone
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><style>
        #{style_css}
        html,body{margin:0;padding:0;background:transparent}
        .cf-plate{position:relative;width:#{size.width}px;height:#{size.height}px;overflow:hidden}
        .cf-plate>img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:#{fx}% #{fy}%}
        .cf-copy{position:absolute;box-sizing:border-box;left:#{pct(z.x)}%;top:#{pct(z.y)}%;width:#{pct(z.w)}%;height:#{pct(z.h)}%;
          overflow:hidden;display:flex;flex-direction:column;justify-content:center;gap:0.5em;color:var(--cf-ink);
          font-family:var(--font-display, var(--font-sans, #{FALLBACK_FONT}))}
        .cf-headline{margin:0;font-weight:800;line-height:1.05;font-size:#{headline_px(size)}px}
        .cf-body{margin:0;line-height:1.3;font-size:#{(headline_px(size) * 0.42).round}px;color:var(--cf-muted)}
        .cf-cta{align-self:flex-start;padding:0.55em 1.1em;border-radius:999px;font-weight:700;
          font-size:#{(headline_px(size) * 0.36).round}px;background:var(--cf-accent);color:var(--cf-on-accent)}
        </style></head><body>
        <div class="cf-plate" data-size="#{esc(size.name)}"><img alt="" src="#{PrototypeCapture.data_uri(plate_path)}">
        <div class="cf-copy">#{copy_html}</div></div>
        </body></html>
      HTML
    end

    def colors = @colors ||= resolve_colors


    def plate_requests
      families.map { |f| { family: f, prompt: plate_prompt(f), size: FAMILY_SIZE[f], quality: @quality } }
    end

    # The cache path the plate lands at, keyed on the same refs generate_plates
    # passes: the second plate references the first, so its key depends on it.
    # Nil when a reference is not on disk yet: the key cannot be known, so the
    # plate is counted as paid.
    def plate_path(req, refs)
      return nil unless refs.all? { |r| r && File.file?(r) }

      key = @imagegen.asset_key(prompt: req[:prompt], size: req[:size], quality: req[:quality], refs: refs)
      WalkthroughCache.path(@cache, :images, key, 'png')
    end

    def generate_plates
      first = nil
      plate_requests.to_h do |req|
        refs = first ? [ first ] : []
        path = @imagegen.generate(prompt: req[:prompt], size: req[:size], quality: req[:quality], refs: refs,
                                  cache_root: @cache, screen: "plate-#{req[:family]}", http: @http)
        first ||= path
        [ req[:family], path ]
      rescue PrototypeImagegen::RequestError => e
        raise PrototypeImagegen::RequestError, "#{req[:family]} plate failed: #{e.message}"
      end
    end

    def render(plates)
      pages = spec.sizes.to_h { |s| [ s.name, html_for(s, plates.fetch(s.family)) ] }
      result = nil
      begin
        @browser.call { |session| result = session.run_function(js_module(pages)) }
      rescue StandardError => e
        raise Unavailable, "browserless failed: #{e.message}"
      end
      raise Unavailable, 'browserless returned no result' unless result.is_a?(Hash)

      overflow = Array(result['overflow'])
      raise OverflowError, "copy overflows zone for size #{overflow.join(', ')}" unless overflow.empty?

      spec.sizes.to_h do |s|
        data = result.dig('shots', s.name)
        raise Unavailable, "browserless returned no shot for size #{s.name}" unless data.is_a?(String) && !data.empty?

        [ s.name, Base64.decode64(data) ]
      end
    end

    def js_module(pages)
      dims = spec.sizes.to_h { |s| [ s.name, [ s.width, s.height ] ] }
      <<~JS
        export default async function ({ page }) {
          const pages = #{JSON.generate(pages)};
          const dims = #{JSON.generate(dims)};
          const shots = {};
          const overflow = [];
          for (const name of Object.keys(pages)) {
            await page.setViewport({ width: dims[name][0], height: dims[name][1], deviceScaleFactor: 1 });
            await page.setContent(pages[name], { waitUntil: "load" });
            await page.evaluate(() => document.fonts.ready);
            const over = await page.evaluate(() => {
              const box = document.querySelector(".cf-copy");
              return box.scrollHeight > box.clientHeight || box.scrollWidth > box.clientWidth;
            });
            if (over) { overflow.push(name); continue; }
            const el = await page.$(".cf-plate");
            shots[name] = await el.screenshot({ encoding: "base64" });
          }
          return { data: overflow.length ? { overflow } : { shots }, type: "application/json" };
        }
      JS
    end

    def write_out
      FileUtils.mkdir_p(@out_dir)
      spec.sizes.map do |s|
        dest = File.join(@out_dir, "#{s.name}.png")
        FileUtils.cp(image_path(s), dest)
        dest
      end
    end

    def zone_on_plate(size, family)
      pw, ph = FAMILY_DIMS.fetch(family)
      scale = [ size.width.to_f / pw, size.height.to_f / ph ].max
      vw = size.width / (pw * scale)
      vh = size.height / (ph * scale)
      ox = (1 - vw) * spec.focal['x']
      oy = (1 - vh) * spec.focal['y']
      z = size.zone
      [ ox + (z.x * vw), oy + (z.y * vh), ox + ((z.x + z.w) * vw), oy + ((z.y + z.h) * vh) ]
    end

    def zone_description(family)
      x0, y0, x1, y1 = plate_zone(family).map { |v| (v * 100).round }
      "#{x0}% to #{x1}% across, #{y0}% to #{y1}% down"
    end

    def copy_html
      c = spec.copy
      parts = [ %(<h1 class="cf-headline">#{esc(c['headline'])}</h1>) ]
      parts << %(<p class="cf-body">#{esc(c['body'])}</p>) if c['body']
      parts << %(<span class="cf-cta">#{esc(c['cta'])}</span>) if c['cta']
      parts.join
    end

    def headline_px(size) = [ (size.height * size.zone.h * 0.22).round, (size.width * size.zone.w * 0.09).round, 18 ].max.then { |px| [ px, 160 ].min }

    def pct(v) = (v * 100).round(3)

    def esc(s) = s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')

    def style_css
      vars = ":root{--cf-ink:#{colors['--ink']};--cf-muted:#{colors['--muted']};--cf-accent:#{colors['--accent']};" \
             "--cf-on-accent:#{colors['--surface'] || colors['--bg']}}"
      tokens_path ? "#{PrototypeCapture.inline_css(tokens_path)}\n#{vars}" : vars
    end

    def resolve_colors
      return FALLBACK_COLORS unless tokens_path

      DiagramPalette.resolve(tokens_path).light
    rescue DiagramPalette::Error
      FALLBACK_COLORS
    end

    def tokens_path
      return @tokens_path if defined?(@tokens_path)

      @tokens_path = begin
        DiagramPalette.locate(repo: @repo)
      rescue StandardError
        nil
      end
    end

    def tokens_digest = tokens_path ? Digest::SHA256.file(tokens_path).hexdigest : 'fallback'

    def browserless_digest = ChangeDocker::BROWSERLESS_IMAGE.split('@').last
  end

  # The heavy hand-off from image.rb. Options: :prompt, :spec (path),
  # :quality, :cache, :out (directory), :max_usd, :estimate_only. Returns the
  # exit code: 0 ok, 1 named failure, 2 usage or bad spec, 3 Docker unavailable.
  module Cli
    module_function

    def run(options, out: $stdout, **deps)
      raise SpecError, 'heavy text needs --spec copy.json' unless options[:spec]

      spec = Spec.load(options[:spec])
      run = Run.new(spec: spec, prompt: options.fetch(:prompt), quality: options.fetch(:quality, PrototypeImagegen::QUALITY_DRAFT),
                    cache: options.fetch(:cache, '.cache'), out_dir: options[:out] || DEFAULT_OUT, **deps)
      usd = run.estimate_usd
      out.puts("image estimate: #{run.families.size} plate(s)#{' (cached)' if usd.zero?}, $#{format('%.2f', usd)} to spend")
      max = options.fetch(:max_usd, 1.0)
      raise CeilingError, "$#{format('%.2f', usd)} would pass the $#{format('%.2f', max)} ceiling" if usd > max + 1e-9
      return 0 if options[:estimate_only]

      run.call.each { |path| out.puts("image: #{path}") }
      0
    rescue SpecError => e
      out.puts("error: #{e.message}")
      2
    rescue Unavailable => e
      out.puts("error: #{e.message}")
      3
    rescue OverflowError, CeilingError, PrototypeImagegen::RequestError, PrototypeImagegen::AttemptCapError,
           WalkthroughEnv::MissingKeyError, SystemCallError, PrototypeCapture::UnsupportedContentError => e
      out.puts("error: #{e.message}")
      1
    end
  end
end
