#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'fileutils'
require 'json'
require_relative 'browserless_js'
require_relative 'change_docker'
require_relative 'prototype_capture'
require_relative 'walkthrough_cache'

# The Figma-style "flats" output of cf:prototype: one still per screen of the
# product's information architecture (key states included, whether or not the
# video uses them), rendered in both a light and a dark theme at device size
# and at 2x, plus one overview board per theme laying the screens out in flow
# order, and an index.md that is a table of contents with context.
#
# Driven by `flats.json` beside the storyboard (see skills/prototype/SKILL.md).
# All browser work runs in the pinned browserless container, the same as
# capture; the board is composed from an HTML grid in that container too, so
# there is no new dependency. A theme is applied through both mechanisms a
# tokens.css may use: the data-theme attribute (and a `dark` class) and
# prefers-color-scheme emulation.
module PrototypeFlats
  THEMES = %w[light dark].freeze
  DEFAULT_VIEWPORT = { 'w' => 1440, 'h' => 900 }.freeze
  BOARD_WIDTH = 2400
  BOARD_BG = { 'light' => '#f2f2f2', 'dark' => '#151515' }.freeze
  BOARD_FG = { 'light' => '#1a1a1a', 'dark' => '#eeeeee' }.freeze
  THUMB_WIDTH = 440
  # Board thumbnails are JPEG at twice their CSS width, so a board of dozens of
  # screens stays far under browserless's 10 MiB request-body cap.
  THUMB_SCALE = 2
  THUMB_QUALITY = 70

  module_function

  def overview_path(root, theme) = File.join(root, 'flats', theme, 'overview.png')

  # -- manifest ------------------------------------------------------------

  def load_manifest(path)
    manifest = JSON.parse(File.read(path))
    root = File.dirname(File.expand_path(path))
    flats = manifest['flats']
    raise ArgumentError, 'flats.json needs a non-empty "flats" array' unless flats.is_a?(Array) && !flats.empty?

    flats.each_with_index { |flat, i| validate_flat!(flat, i, root) }
    manifest
  end

  def validate_flat!(flat, index, root)
    label = "flats[#{index}]"
    %w[section screen html purpose goal].each do |key|
      raise ArgumentError, "#{label} needs a non-empty #{key}" if flat[key].to_s.strip.empty?
    end
    reqs = flat['requirements']
    raise ArgumentError, "#{label} requirements must be an array of ids" unless reqs.nil? || reqs.is_a?(Array)
    raise ArgumentError, "#{label} html not found: #{flat['html']}" unless File.file?(File.join(root, flat['html']))
  end

  def slug(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')

  # Flow order is manifest order. The state joins the filename unless it is
  # the default, so two states of one screen never collide.
  def entries(manifest)
    manifest['flats'].each_with_index.map do |flat, i|
      state = flat['state'].to_s.empty? ? 'default' : flat['state']
      parts = [ format('%02d', i + 1), slug(flat['section']), slug(flat['screen']) ]
      parts << slug(state) unless state == 'default'
      { name: parts.join('-'), section: flat['section'], screen: flat['screen'], state: state, html: flat['html'],
        purpose: flat['purpose'], goal: flat['goal'], requirements: Array(flat['requirements']),
        patch: flat['patch'] }
    end
  end

  # -- browser modules -----------------------------------------------------

  # Shared page setup for every browser module: a fresh context, a page that
  # collects its own errors, and the starting viewport.
  def page_prelude_js(width:, height:)
    <<~JS
      #{BrowserlessJs.fresh_context_js}
      const browser = basePage.browser();
      const context = await newBrowserContext(browser);
      const page = context ? await context.newPage() : await browser.newPage();
      const pageErrors = [];
      page.on("pageerror", (err) => pageErrors.push(String(err && err.message || err)));
      await page.setViewport({ width: #{width}, height: #{height}, deviceScaleFactor: 1 });
    JS
  end

  # One screenshot of the loaded page at a device scale factor, after two
  # real frames: the inlined fixed clock never advances its own rAF, so waiting
  # on it would hang until the browserless timeout.
  def capture_js(target, width:, height:, scale:, options: '')
    <<~JS
      await page.setViewport({ width: #{width}, height: #{height}, deviceScaleFactor: #{scale} });
      await page.evaluate(() => new Promise((r) => { const raf = window.__cfRealRaf || requestAnimationFrame; raf(() => raf(r)); }));
      #{target} = await page.screenshot({ encoding: "base64"#{options} });
    JS
  end

  # Device scale factor that renders a page of `width` at THUMB_SCALE x THUMB_WIDTH pixels.
  def thumb_scale(width) = (THUMB_WIDTH * THUMB_SCALE / width.to_f).round(4)

  # One flat in one theme: the 1x, the 2x, and a small JPEG thumbnail of the same page.
  def function_module(html:, theme:, viewport:, state:, prng_seed:)
    vp = DEFAULT_VIEWPORT.merge(viewport || {})
    size = { width: vp['w'], height: vp['h'] }
    <<~JS
      export default async function ({ page: basePage }) {
        #{page_prelude_js(**size)}
        const theme = #{JSON.generate(theme)};
        const locale = #{JSON.generate(PrototypeCapture::LOCALE)};
        await page.setExtraHTTPHeaders(#{BrowserlessJs.locale_header_js});
        await page.emulateMediaFeatures([ { name: "prefers-color-scheme", value: theme } ]);
        #{BrowserlessJs.inline_html_js(PrototypeCapture.with_document_scripts(html, prng_seed: prng_seed, state: state), page_var: 'page')}
        await page.evaluate((theme) => {
          document.documentElement.setAttribute("data-theme", theme);
          document.documentElement.classList.toggle("dark", theme === "dark");
        }, theme);
        const shots = {};
        #{capture_js('shots["1x"]', **size, scale: 1)}
        #{capture_js('shots["2x"]', **size, scale: 2)}
        #{capture_js('shots["thumb"]', **size, scale: thumb_scale(size[:width]), options: ", type: \"jpeg\", quality: #{THUMB_QUALITY}")}
        if (context) await context.close();
        return { data: { shots, blockedRequests, pageErrors }, type: "application/json" };
      }
    JS
  end

  # The overview board: one full-page screenshot of an HTML grid.
  def board_module(html)
    <<~JS
      export default async function ({ page: basePage }) {
        #{page_prelude_js(width: BOARD_WIDTH, height: 1000)}
        #{BrowserlessJs.inline_html_js(html, page_var: 'page')}
        const png = await page.screenshot({ encoding: "base64", fullPage: true });
        if (context) await context.close();
        return { data: { png, blockedRequests, pageErrors }, type: "application/json" };
      }
    JS
  end

  # Consecutive entries sharing a section, in flow order.
  def by_section(entries) = entries.chunk_while { |a, b| a[:section] == b[:section] }

  # Sections are rows in flow order, screens run left to right within a row,
  # like frames on a Figma page. Images are data URIs so the board needs no
  # network and no file access.
  def board_html(shots, theme:)
    rows = by_section(shots).map do |group|
      cells = group.map { |s| board_cell(s) }.join
      "<section><h2>#{CGI.escapeHTML(group.first[:section])}</h2><div class=\"row\">#{cells}</div></section>"
    end
    <<~HTML
      <!doctype html><html data-theme="#{theme}"><head><meta charset="utf-8"><style>
      body{margin:0;padding:48px;background:#{BOARD_BG.fetch(theme)};color:#{BOARD_FG.fetch(theme)};font:16px system-ui,sans-serif}
      h2{margin:32px 0 16px;font-size:24px}.row{display:flex;flex-wrap:wrap;gap:32px}
      figure{margin:0;width:#{THUMB_WIDTH}px}img{display:block;width:100%;border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.35)}
      figcaption{margin-top:8px;font-size:14px;opacity:.8}
      </style></head><body>#{rows.join}</body></html>
    HTML
  end

  def board_cell(shot)
    src = "data:image/jpeg;base64,#{Base64.strict_encode64(shot[:thumb])}"
    label = CGI.escapeHTML("#{shot[:screen]} (#{shot[:state]})")
    "<figure><img src=\"#{src}\" alt=\"#{label}\"><figcaption>#{label}</figcaption></figure>"
  end

  # -- index ---------------------------------------------------------------

  def index_md(entries)
    out = [ '# Flats', '', 'Stills of every screen in the information architecture, in flow order, in both themes. ' \
                           'Generated by `prototype_flats.rb`; do not edit.', '' ]
    out << THEMES.map { |t| "[Overview, #{t}](#{t}/overview.png)" }.join(' | ')
    out << ''
    by_section(entries).each do |group|
      out << "## #{group.first[:section]}" << ''
      group.each { |e| out.concat(index_entry(e)) }
    end
    "#{out.join("\n")}\n"
  end

  def index_entry(entry)
    reqs = entry[:requirements].empty? ? 'none' : entry[:requirements].join(', ')
    links = THEMES.map do |t|
      "[#{t.capitalize}](#{t}/#{entry[:name]}.png) ([2x](#{t}/#{entry[:name]}@2x.png))"
    end
    [ "### #{entry[:screen]} (#{entry[:state]})", '',
      "- Purpose: #{entry[:purpose]}", "- User goal: #{entry[:goal]}", "- Requirements: #{reqs}",
      "- Source: `#{entry[:html]}`", "- Images: #{links.join(' | ')}", '' ]
  end

  # -- driving -------------------------------------------------------------

  def check!(result, label)
    PrototypeCapture.check_result!(result, label)
  end

  def seed_for(root)
    path = File.join(root, 'data', 'seed.json')
    File.file?(path) ? JSON.parse(File.read(path)) : {}
  end

  # Renders everything into <root>/flats and returns that directory.
  # `session` responds to run_function, as in PrototypeCapture.capture.
  def run(session:, root:, manifest_path: File.join(root, 'flats.json'))
    manifest = load_manifest(manifest_path)
    out = File.join(root, 'flats')
    WalkthroughCache.ensure_gitignore(root)
    list = entries(manifest)
    boards = THEMES.to_h { |t| [ t, [] ] }
    THEMES.each do |theme|
      FileUtils.mkdir_p(File.join(out, theme))
      list.each { |e| boards[theme] << render_flat(session, e, theme, root, manifest) }
      html = board_html(boards[theme], theme: theme)
      png = check!(session.run_function(board_module(html)), "overview #{theme}")['png']
      File.binwrite(overview_path(root, theme), Base64.decode64(png))
    end
    File.write(File.join(out, 'index.md'), index_md(list))
    out
  end

  def render_flat(session, entry, theme, root, manifest)
    out = File.join(root, 'flats')
    seed = seed_for(root)
    html = PrototypeCapture.inline_screen(File.join(root, entry[:html]))
    state = PrototypeCapture.resolve_state(seed, patch: entry[:patch])
    mod = function_module(html: html, theme: theme, viewport: manifest['viewport'], state: state,
                          prng_seed: PrototypeCapture.default_prng_seed(entry[:name]))
    shots = check!(session.run_function(mod), "#{entry[:name]} #{theme}")['shots']
    one = Base64.decode64(shots.fetch('1x'))
    File.binwrite(File.join(out, theme, "#{entry[:name]}.png"), one)
    File.binwrite(File.join(out, theme, "#{entry[:name]}@2x.png"), Base64.decode64(shots.fetch('2x')))
    entry.merge(thumb: Base64.decode64(shots.fetch('thumb')))
  end
end

if __FILE__ == $PROGRAM_NAME
  root = ARGV[0] || abort('usage: prototype_flats.rb walkthrough/<slug> [--manifest flats.json]')
  manifest = ARGV.include?('--manifest') ? ARGV[ARGV.index('--manifest') + 1] : File.join(root, 'flats.json')
  root = File.expand_path(root)
  out = ChangeDocker.with_browserless(network: nil) do |session|
    PrototypeFlats.run(session: session, root: root, manifest_path: File.expand_path(manifest))
  end
  puts "flats #{out}"
end
