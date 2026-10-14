# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "zlib"
require_relative "../scripts/change_coverage_page"
require_relative "../scripts/change_coverage_brand"
require_relative "../scripts/qa_report_config"

# Covers the QA coverage page: brand resolution (tokens, contrast, fonts,
# logos), the rendered template's file:// and safety rules, byte-identical
# regeneration, and the page's pure model run under Node.
class ChangeCoveragePageTest < Minitest::Test
  HARNESS = File.expand_path("support/coverage_page_harness.mjs", __dir__)
  TEMPLATE = File.expand_path("../skills/change/reference/qa-coverage.html.erb", __dir__)

  BRAND_YAML = <<~YAML
    qa_report:
      title: Example Co QA coverage
      brand:
        name: Example Co
        font:
          family: "Source Sans 3, Arial"
        colors:
          light: { ground: "#ffffff", ink: "#1b1f24", accent: "#2b6cb0" }
          dark:  { ground: "#121417", ink: "#e9ecef", accent: "#7fb0e8" }
  YAML

  def setup
    @root = Dir.mktmpdir("cf-coverage-page")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write_change(body)
    File.write(File.join(@root, "CHANGE.md"), "---\n#{body}---\n\n# fixture-app\n")
  end

  def settings(body = BRAND_YAML)
    write_change(body)
    QaReportConfig.load(@root)
  end

  def resolve(settings_or_nil = settings) = ChangeCoverageBrand.resolve(settings_or_nil, repo_root: @root)

  def brand_settings(brand_attrs)
    base = QaReportConfig.defaults("fixture-app")
    brand = QaReportConfig::Brand.new(**{ name: "Example Co", logo: nil, logo_dark: nil, font_family: nil,
                                         light: nil, dark: nil }.merge(brand_attrs))
    base.with(declared: true, brand: brand)
  end

  def render(resolved = resolve) = ChangeCoveragePage.render(resolved)

  # The CSS block of one theme scope, by the selector that opens it.
  def scope(html, opener)
    start = html.index(opener)
    assert start, "missing theme scope #{opener}"
    html[start, html.index("}", start) - start]
  end

  SCOPES = {
    light: ":root {",
    media_dark: ':root:not([data-theme="light"]) {',
    forced_dark: ':root[data-theme="dark"] {'
  }.freeze

  # --- brand tokens ---------------------------------------------------------------

  def test_invented_brand_renders_its_name_and_tokens_in_all_three_scopes
    resolved = resolve
    html = render(resolved)
    assert_includes html, "<p class=\"brand-name\">Example Co</p>"
    assert_includes html, "<title>Example Co QA coverage</title>"
    assert_includes scope(html, SCOPES[:light]), "--ground: #ffffff;"
    assert_includes scope(html, SCOPES[:light]), "--accent: #2b6cb0;"
    [ :media_dark, :forced_dark ].each do |key|
      block = scope(html, SCOPES[key])
      assert_includes block, "--ground: #121417;"
      assert_includes block, "--ink: #e9ecef;"
      assert_includes block, "--accent: #7fb0e8;"
      assert_includes block, "--chart-surface: #1a1a19;"
      assert_includes block, "--s1: #3987e5;"
      assert_includes block, "--fail: #ff6b60;"
    end
    assert_includes html, 'font: 15px/1.55 "Source Sans 3", "Arial", -apple-system'
    assert_empty resolved.warnings
  end

  def test_derived_tokens_are_mixes_of_ground_and_ink
    light = resolve.light
    assert_equal ChangeCoverageBrand.mix_hex("#ffffff", "#1b1f24", 0.04), light["surface"]
    assert_equal ChangeCoverageBrand.mix_hex("#ffffff", "#1b1f24", 0.14), light["border"]
    assert_operator ChangeCoverageBrand.contrast(light["muted"], light["ground"]), :>=, 4.5
    assert_operator ChangeCoverageBrand.contrast(light["muted"], light["surface"]), :>=, 4.5
    assert_equal ChangeCoverageBrand::TOKENS, light.keys
  end

  def test_no_brand_renders_exactly_the_neutral_fallback
    resolved = resolve(nil)
    assert_equal ChangeCoverageBrand::NEUTRAL_LIGHT, resolved.light
    assert_equal ChangeCoverageBrand::NEUTRAL_DARK, resolved.dark
    assert_equal ChangeCoverageBrand::SYSTEM_STACK, resolved.font_stack
    html = render(resolved)
    light = scope(html, SCOPES[:light])
    { "ground" => "#ffffff", "ink" => "#16181d", "muted" => "#5c6370", "border" => "#e3e6ea", "surface" => "#f7f8fa",
      "accent" => "#1a4fd6", "accent-text" => "#1a4fd6", "focus" => "#1a4fd6", "on-accent" => "#ffffff" }
      .each { |k, v| assert_includes light, "--#{k}: #{v};" }
    dark = scope(html, SCOPES[:forced_dark])
    { "ground" => "#14161a", "ink" => "#e8eaee", "muted" => "#9aa2ad", "border" => "#2a2e35", "surface" => "#1b1e24",
      "accent" => "#7aa2ff", "accent-text" => "#7aa2ff", "focus" => "#7aa2ff", "on-accent" => "#14161a" }
      .each { |k, v| assert_includes dark, "--#{k}: #{v};" }
    assert_empty resolved.warnings
  end

  def test_status_and_chart_colors_are_fixed_whatever_the_brand
    light = scope(render, SCOPES[:light])
    %w[--pass:\ #1f7a4d --warn:\ #8a6100 --fail:\ #b3261e --chart-surface:\ #fcfcfb --chart-ink:\ #0b0b0b
       --chart-muted:\ #52514e --s1:\ #2a78d6 --s2:\ #eb6834 --s3:\ #1baf7a --s4:\ #eda100].each do |token|
      assert_includes light, token
    end
  end

  # --- escaping and validation -------------------------------------------------------

  def test_brand_name_is_html_escaped
    html = render(resolve(brand_settings(name: "<script>x</script>")))
    refute_includes html, "<script>x</script>"
    assert_includes html, "&lt;script&gt;x&lt;/script&gt;"
  end

  def test_bad_font_and_non_hex_color_are_rejected_with_warnings_by_the_reader
    s = settings(<<~YAML)
      qa_report:
        brand:
          name: Example Co
          font: { family: "Arial;} body { color: red" }
          colors:
            light: { ground: "#ffffff", ink: "#1b1f24", accent: "blue" }
    YAML
    assert(s.warnings.any? { |w| w.start_with?("qa_report.brand.font.family:") })
    assert(s.warnings.any? { |w| w.start_with?("qa_report.brand.colors.light.accent:") })
    resolved = resolve(s)
    assert_equal ChangeCoverageBrand::NEUTRAL_LIGHT, resolved.light
    assert_equal ChangeCoverageBrand::SYSTEM_STACK, resolved.font_stack
    refute_includes render(resolved), "color: red"
  end

  def test_resolver_rechecks_a_hand_built_brand
    resolved = resolve(brand_settings(font_family: "Arial;}", light: { ground: "#fff", ink: "#000", accent: "url(x)" }))
    assert(resolved.warnings.any? { |w| w.start_with?("qa_report.brand.font.family:") })
    assert(resolved.warnings.any? { |w| w.start_with?("qa_report.brand.colors.light.accent:") })
    assert_equal ChangeCoverageBrand::SYSTEM_STACK, resolved.font_stack
    assert_equal ChangeCoverageBrand::NEUTRAL_LIGHT, resolved.light
    refute_includes render(resolved), "url(x)"
  end

  # --- determinism -----------------------------------------------------------------

  def test_two_renders_are_byte_equal_and_carry_no_home_or_timestamp
    first = render
    assert_equal first, render
    refute_includes first, Dir.home
    refute_includes first, @root
    refute_match(/\d{4}-\d{2}-\d{2}T/, first)
  end

  def test_write_leaves_an_unchanged_file_alone
    dir = File.join(@root, "store")
    resolved = resolve
    assert_equal :written, ChangeCoveragePage.write(dir, resolved)
    path = File.join(dir, "index.html")
    past = Time.at(Time.now.to_i - 3600)
    File.utime(past, past, path)
    assert_equal :unchanged, ChangeCoveragePage.write(dir, resolved)
    assert_equal past.to_i, File.mtime(path).to_i
    assert_equal [ "index.html" ], Dir.children(dir)
    assert_equal :written, ChangeCoveragePage.write(dir, resolve(nil))
  end

  # --- file:// and safety rules ---------------------------------------------------------

  def test_page_has_no_network_or_module_and_loads_data_first
    html = render
    refute_match(%r{https?://}, html)
    refute_includes html, 'type="module"'
    refute_includes html, "fetch("
    refute_includes html, "XMLHttpRequest"
    refute_includes html, "Worker("
    data = html.index('<script src="report-data.js"></script>')
    assert data, "classic report-data.js script missing"
    model = html.index('<script id="cf-coverage-model">')
    view = html.index('<script id="cf-coverage-view">')
    assert model && view
    assert_operator data, :<, model
    assert_operator model, :<, view
    assert_equal 3, html.scan("<script").size
  end

  def test_page_never_uses_an_html_sink
    html = render
    %w[innerHTML outerHTML insertAdjacentHTML document.write eval( new\ Function].each do |sink|
      refute_includes html, sink
    end
    assert_includes html, "textContent"
    assert_includes html, "/^https:\\/\\//.test"
    assert_includes html, 'doc.querySelector("svg").namespaceURI'
  end

  def test_theme_storage_is_guarded
    html = render
    html.scan(/^.*localStorage.*$/).each do |line|
      assert_match(/try \{/, line, "unguarded localStorage use: #{line.strip}")
    end
    assert_includes html, '"cf-coverage-theme"'
    assert_includes html, '<html lang="en">'
    assert_includes html, "prefers-reduced-motion"
    assert_includes html, ":focus-visible { outline: 2px solid var(--focus)"
  end

  def test_page_carries_its_sections_in_order
    html = render
    markers = [ 'class="masthead"', 'id="filters"', 'id="tiles-toolkit"', 'id="trend-chart"', 'id="routes-table"',
                'id="cases-table"', 'id="failing-table"', 'id="groups-table"', 'id="history-table"', "<footer>" ]
    positions = markers.map { |m| html.index(m) }
    assert positions.all?, "missing section: #{markers.zip(positions).select { |_, p| p.nil? }.map(&:first)}"
    assert_equal positions.sort, positions
    assert_includes html, "Measured by Change Fabric"
    assert_includes html, "Routes are matched literally; /claims/123 and /claims/:id are different routes."
    assert_includes html, "Generated by Change Fabric"
    assert_includes html, "View as table"
    assert_includes html, "Percentages are rounded down to one decimal"
  end

  # --- logo ---------------------------------------------------------------------------

  def png_bytes
    chunk = lambda do |type, data|
      [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
    end
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [ 1, 1, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate("\x00\xff\x00\x00".b)) + chunk.call("IEND", "")
  end

  def test_png_logo_becomes_an_img_data_uri
    FileUtils.mkdir_p(File.join(@root, "docs"))
    File.binwrite(File.join(@root, "docs/logo.png"), png_bytes)
    resolved = resolve(brand_settings(logo: "docs/logo.png"))
    assert_empty resolved.warnings
    html = render(resolved)
    assert_includes html, '<img class="logo logo-light" src="data:image/png;base64,'
    assert_includes html, 'alt="Example Co logo"'
  end

  def test_svg_logo_with_script_is_only_ever_base64_inside_img
    svg = %(<?xml version="1.0"?>\n<!-- logo -->\n<svg xmlns="x"><script>alert(1)</script><rect/></svg>\n)
    File.write(File.join(@root, "logo.svg"), svg)
    resolved = resolve(brand_settings(logo: "logo.svg", logo_dark: "logo.svg"))
    assert_empty resolved.warnings
    html = render(resolved)
    assert_includes html, 'src="data:image/svg+xml;base64,'
    assert_includes html, "has-dark-logo"
    refute_includes html, "<script>alert"
    assert_equal 1, html.scan("<svg").size, "only the static namespace svg may appear"
    assert_includes html, '<svg class="ns-source"'
  end

  def test_logo_problems_warn_and_render_a_text_header
    File.binwrite(File.join(@root, "big.png"), png_bytes + ("\0" * (256 * 1024)))
    File.write(File.join(@root, "logo.txt"), "not an image")
    outside = Dir.mktmpdir("cf-outside")
    File.binwrite(File.join(outside, "logo.png"), png_bytes)
    File.symlink(File.join(outside, "logo.png"), File.join(@root, "link.png"))
    {
      "big.png" => "over 256 KB",
      "../logo.png" => "outside the repo root",
      "link.png" => "outside the repo root",
      "logo.txt" => "not a PNG, JPEG, WebP or SVG",
      "missing.png" => "was not found"
    }.each do |path, reason|
      resolved = resolve(brand_settings(logo: path))
      assert_nil resolved.logo_uri, path
      assert(resolved.warnings.any? { |w| w.start_with?("qa_report.brand.logo: #{path}") && w.include?(reason) },
             "#{path}: #{resolved.warnings.inspect}")
      refute_includes render(resolved), "<img", path
    end
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  def test_sniff_detects_types_by_bytes
    assert_equal "image/png", ChangeCoverageBrand.sniff(png_bytes)
    assert_equal "image/jpeg", ChangeCoverageBrand.sniff("\xFF\xD8\xFF\xE0rest".b)
    assert_equal "image/webp", ChangeCoverageBrand.sniff("RIFF\x10\x00\x00\x00WEBPVP8 ".b)
    assert_equal "image/svg+xml", ChangeCoverageBrand.sniff("<!DOCTYPE svg>\n<svg viewBox='0 0 1 1'></svg>")
    assert_nil ChangeCoverageBrand.sniff("<html><svg></svg></html>")
    assert_nil ChangeCoverageBrand.sniff("\xFF\xFE\x00bad".b)
  end

  # --- contrast -----------------------------------------------------------------------

  def test_low_contrast_accent_is_deepened_for_text_and_kept_on_marks
    resolved = resolve(brand_settings(light: { ground: "#ffffff", ink: "#1b1f24", accent: "#8fb3e0" }))
    light = resolved.light
    assert_equal "#8fb3e0", light["accent"]
    refute_equal "#8fb3e0", light["accent-text"]
    assert_operator ChangeCoverageBrand.contrast(light["accent-text"], light["ground"]), :>=, 4.5
    assert_operator ChangeCoverageBrand.contrast(light["accent-text"], light["surface"]), :>=, 4.5
    assert_equal light["accent-text"], light["focus"]
    before = ChangeCoverageBrand.shown_ratio(worst_ratio("#8fb3e0", light))
    after = ChangeCoverageBrand.shown_ratio(worst_ratio(light["accent-text"], light))
    expected = "qa_report.brand.colors.light.accent #8fb3e0 is #{before}:1 on ground or surface; " \
               "text and focus use #{light['accent-text']} (#{after}:1)"
    assert_includes resolved.warnings, expected
    html = render(resolved)
    assert_includes scope(html, SCOPES[:light]), "--accent: #8fb3e0;"
    assert_match(/\.bar-fill \{[^}]*background: var\(--accent\)/, html)
    assert_match(/\.masthead \{[^}]*var\(--accent\)/, html)
    assert_match(/a \{ color: var\(--accent-text\)/, html)
  end

  def test_low_contrast_ink_is_stepped_away_from_ground
    resolved = resolve(brand_settings(light: { ground: "#ffffff", ink: "#9a9a9a", accent: "#1a4fd6" }))
    assert_operator ChangeCoverageBrand.contrast(resolved.light["ink"], "#ffffff"), :>=, 4.5
    assert(resolved.warnings.any? { |w| w.start_with?("qa_report.brand.colors.light.ink #9a9a9a is") })
  end

  def worst_ratio(color, theme)
    [ theme["ground"], theme["surface"] ].map { |bg| ChangeCoverageBrand.contrast(color, bg) }.min
  end

  def test_ink_that_misses_on_surface_is_stepped_so_muted_and_accent_text_reach_it
    resolved = resolve(brand_settings(light: { ground: "#ffffff", ink: "#757575", accent: "#8fb3e0" }))
    light = resolved.light
    assert_equal "#f9f9f9", ChangeCoverageBrand.mix_hex("#ffffff", "#757575", 0.04)
    assert_operator ChangeCoverageBrand.contrast("#757575", "#f9f9f9"), :<, 4.5
    %w[ink muted accent-text focus].each do |token|
      assert_operator worst_ratio(light[token], light), :>=, 4.5, token
    end
    assert(resolved.warnings.any? { |w| w.start_with?("qa_report.brand.colors.light.ink #757575 is 4.3:1 on ground or surface") })
    refute(resolved.warnings.any? { |w| w.include?("(4.6:1)") })
  end

  TEXT_SLOTS = { "ink" => "ink", "muted" => "muted", "accent-text" => "accent", "focus" => "accent" }.freeze

  def test_every_derived_text_token_reads_on_ground_and_surface_or_warns_by_slot
    rng = Random.new(20_261_013)
    color = -> { format("#%06x", rng.rand(0x1000000)) }
    300.times do
      theme = -> { { ground: color.call, ink: color.call, accent: color.call } }
      dark = rng.rand(2).zero? ? nil : theme.call
      resolved = resolve(brand_settings(light: theme.call, dark: dark))
      { "light" => resolved.light, "dark" => resolved.dark }.each do |name, tokens|
        TEXT_SLOTS.each do |token, slot|
          next if worst_ratio(tokens[token], tokens) >= 4.5

          prefix = "qa_report.brand.colors.#{name}.#{slot}"
          assert(resolved.warnings.any? { |w| w.start_with?(prefix) && w.include?("below 4.5:1") },
                 "#{name} #{token} #{tokens[token]} below 4.5:1 with no warning for #{prefix}: #{resolved.warnings.inspect}")
        end
      end
    end
  end

  def test_punctuation_only_font_family_falls_back_to_the_system_stack
    [ ",", "'\"", " , ' " ].each do |family|
      assert_equal ChangeCoverageBrand::SYSTEM_STACK, resolve(brand_settings(font_family: family)).font_stack, family
    end
    assert_equal %("Arial", #{ChangeCoverageBrand::SYSTEM_STACK}), resolve(brand_settings(font_family: "Arial,")).font_stack
  end

  def test_dark_only_brand_keeps_neutral_light_and_asks_for_a_light_theme
    resolved = resolve(brand_settings(dark: { ground: "#121417", ink: "#e9ecef", accent: "#7fb0e8" }))
    assert_equal ChangeCoverageBrand::NEUTRAL_LIGHT, resolved.light
    assert_equal "#121417", resolved.dark["ground"]
    assert(resolved.warnings.any? do |w|
      w.start_with?("qa_report.brand.colors.light: not declared") && w.include?("declare qa_report.brand.colors.light")
    end)
  end

  def test_unusable_dark_theme_names_the_fallback_it_actually_takes
    bad_dark = { ground: "#121417", ink: "nope", accent: "#7fb0e8" }
    with_light = resolve(brand_settings(light: { ground: "#ffffff", ink: "#1b1f24", accent: "#2b6cb0" }, dark: bad_dark))
    assert_includes with_light.warnings, "qa_report.brand.colors.dark: theme not used; falling back to the derived dark theme"
    without_light = resolve(brand_settings(dark: bad_dark))
    assert_includes without_light.warnings, "qa_report.brand.colors.dark: theme not used; falling back to the neutral dark theme"
    assert_equal ChangeCoverageBrand::NEUTRAL_DARK, without_light.dark
    refute(without_light.warnings.any? { |w| w.include?("not declared") })
  end

  def test_theme_toggle_is_named_by_its_visible_text
    html = render
    assert_match(%r{<button type="button" class="theme-toggle" id="theme-toggle">Theme: auto</button>}, html)
    refute_includes html, "Color theme"
  end

  def test_undeclared_dark_swaps_ground_and_ink_and_lifts_the_accent
    resolved = resolve(brand_settings(light: { ground: "#ffffff", ink: "#1b1f24", accent: "#1d3f73" }))
    dark = resolved.dark
    assert_equal "#1b1f24", dark["ground"]
    assert_equal "#ffffff", dark["ink"]
    assert_operator ChangeCoverageBrand.contrast("#1d3f73", "#1b1f24"), :<, 3.0
    assert_operator ChangeCoverageBrand.contrast(dark["accent"], dark["ground"]), :>=, 3.0
    assert_equal ChangeCoverageBrand.step_until("#1d3f73", "#ffffff") { |c| ChangeCoverageBrand.contrast(c, "#1b1f24") >= 3.0 }.first,
                 dark["accent"]
    assert_equal ChangeCoverageBrand.mix_hex("#1b1f24", "#ffffff", 0.04), dark["surface"]
    assert_operator ChangeCoverageBrand.contrast(dark["accent-text"], dark["ground"]), :>=, 4.5
    assert_operator ChangeCoverageBrand.contrast(dark["muted"], dark["surface"]), :>=, 4.5
  end

  def test_status_colors_low_on_a_brand_ground_only_warn
    resolved = resolve(brand_settings(light: { ground: "#b3261e", ink: "#ffffff", accent: "#ffffff" }))
    assert(resolved.warnings.any? { |w| w.include?("status fail #b3261e") })
    assert_includes scope(render(resolved), SCOPES[:light]), "--fail: #b3261e;"
  end

  # --- slop glyphs ---------------------------------------------------------------------

  def test_template_contains_no_slop_glyphs
    text = File.read(TEMPLATE, encoding: "UTF-8")
    [ 0x2014, 0x2022, 0x2026, 0x2018, 0x2019, 0x201C, 0x201D ].map { |code| code.chr(Encoding::UTF_8) }.each do |glyph|
      refute_includes text, glyph, "template contains U+#{glyph.ord.to_s(16).upcase}"
    end
  end

  # --- the model, under Node ---------------------------------------------------------

  def node!
    skip "node not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def run_model(data, exprs)
    path = File.join(@root, "index.html")
    File.write(path, render(resolve(nil)))
    out, err, status = Open3.capture3("node", HARNESS, path, stdin_data: JSON.generate({ data: data, exprs: exprs }))
    assert status.success?, "harness failed: #{err}"
    result = JSON.parse(out)
    result.each { |name, value| refute(value.is_a?(Hash) && value.key?("error"), "#{name}: #{value}") }
    result
  end

  def run_record(id, at, branch: "main", trunk: true, scope: "all", source: "change_run", profile: "staging", **families)
    {
      "schema" => 1, "id" => id, "recorded_at" => at, "source" => source, "scope" => scope, "profile" => profile,
      "git" => { "branch" => branch, "short_sha" => id[0, 7], "trunk" => trunk, "pr" => nil },
      "lanes" => nil, "routes" => nil, "cases" => nil, "findings" => nil, "imports" => nil
    }.merge(families.transform_keys(&:to_s))
  end

  def routes(exercised, total) = { "declared_total" => total, "declared_exercised" => exercised, "items" => [] }

  def coverage(covered, total, label: "unit")
    { "coverage" => [ { "label" => label, "format" => "jacoco", "line" => { "covered" => covered, "total" => total },
                        "branch" => nil, "groups" => [] } ], "test_results" => [] }
  end

  def test_model_floor_pct
    node!
    r = run_model({ "runs" => [] }, { "a" => "M.floorPct(2, 3)", "b" => "M.floorPct(1, 0)", "c" => "M.floorPct(999, 1000)" })
    assert_equal 66.6, r["a"]
    assert_nil r["b"]
    assert_equal 99.9, r["c"]
  end

  def test_model_dedupes_orders_and_excludes_unreadable_runs
    node!
    runs = [
      run_record("b-run", "2026-10-02T00:00:00Z"),
      run_record("a-run", "2026-10-01T00:00:00Z", routes: routes(1, 4)),
      run_record("a-run", "2026-10-01T00:00:00Z", routes: routes(3, 4)),
      run_record("c-run", "2026-10-02T00:00:00Z"),
      run_record("new-run", "2026-10-03T00:00:00Z").merge("schema" => 2),
      run_record("bad-run", "2026-10-03T00:00:00Z").tap { |r| r.delete("schema") }
    ]
    r = run_model({ "runs" => runs }, {
      "ids" => "N.runs.map(function (r) { return r.id; })",
      "kept" => "N.runs[0].routes.declared_exercised",
      "excluded" => "N.excluded",
      "history" => "M.history(N).map(function (r) { return [r.id, r.note]; })"
    })
    assert_equal %w[a-run b-run c-run], r["ids"]
    assert_equal 3, r["kept"]
    newer = r["excluded"].find { |x| x["id"] == "new-run" }
    assert_equal "newer", newer["kind"]
    assert_equal "written by a newer toolkit (schema 2)", newer["reason"]
    assert_equal "invalid record", r["excluded"].find { |x| x["id"] == "bad-run" }["reason"]
    assert_includes r["history"], [ "new-run", "written by a newer toolkit (schema 2)" ]
    assert_includes r["history"], [ "bad-run", "invalid record" ]
  end

  def test_model_reports_a_missing_family_as_null_not_zero
    node!
    runs = [ run_record("r1", "2026-10-01T00:00:00Z", routes: routes(2, 3)) ]
    r = run_model({ "runs" => runs }, {
      "hl" => "M.headline(N.runs, M.defaultFilters(N.runs).filters)",
      "zero" => "M.metrics.routes({ routes: { declared_total: 0, declared_exercised: 0 } })"
    })
    hl = r["hl"]
    assert_equal 66.6, hl["routes"]["value"]["pct"]
    %w[cases lanes findings line branch tests].each { |f| assert_nil hl[f]["value"], f }
    assert_nil r["zero"]["pct"]
  end

  def test_model_defaults_to_full_scope_trunk_runs
    node!
    runs = [
      run_record("t1", "2026-10-01T00:00:00Z", routes: routes(1, 4)),
      run_record("f1", "2026-10-02T00:00:00Z", branch: "feature/x", trunk: false, routes: routes(4, 4)),
      run_record("t2", "2026-10-03T00:00:00Z", scope: "testcases", routes: routes(4, 4))
    ]
    r = run_model({ "runs" => runs }, {
      "d" => "M.defaultFilters(N.runs)",
      "hl" => "M.headline(N.runs, M.defaultFilters(N.runs).filters).routes"
    })
    assert_equal({ "app" => "", "profile" => "", "branch" => "@trunk", "scope" => "all", "source" => "" }, r["d"]["filters"])
    assert_nil r["d"]["fallbackBranch"]
    assert_equal "t1", r["hl"]["runId"]
    assert_equal 25.0, r["hl"]["value"]["pct"]
  end

  def test_model_falls_back_to_latest_full_scope_run_with_its_branch
    node!
    runs = [
      run_record("f1", "2026-10-01T00:00:00Z", branch: "feature/a", trunk: false, routes: routes(1, 2)),
      run_record("f2", "2026-10-02T00:00:00Z", branch: "feature/b", trunk: false, routes: routes(2, 2)),
      run_record("t1", "2026-10-03T00:00:00Z", scope: "a11y", routes: routes(0, 2))
    ]
    r = run_model({ "runs" => runs }, {
      "d" => "M.defaultFilters(N.runs)",
      "hl" => "M.headline(N.runs, M.defaultFilters(N.runs).filters).routes.runId"
    })
    assert_equal "feature/b", r["d"]["fallbackBranch"]
    assert_equal "feature/b", r["d"]["filters"]["branch"]
    assert_equal "f2", r["hl"]
  end

  # Every app of a multi-app sweep records its own run at the same instant.
  # The page shows one app at a time, so tiles, deltas and the trend compare an
  # app only with itself, and a repo-wide import counts under every app.
  def test_model_keeps_apps_of_a_multi_app_store_apart
    node!
    runs = %w[aaaaaaa bbbbbbb].each_with_index.flat_map do |sha, i|
      at = "2026-10-0#{i + 1}T00:00:00Z"
      [ run_record("#{sha}-run-api", at, app: "api", routes: routes(9, 10)),
        run_record("#{sha}-run-web", at, app: "web", routes: routes(2, 10)) ]
    end
    runs << run_record("ccccccc-import", "2026-10-03T00:00:00Z", scope: "import", source: "import",
                       imports: coverage(80, 100))
    r = run_model({ "runs" => runs }, {
      "d" => "M.defaultFilters(N.runs)",
      "opts" => "M.options(N.runs).apps",
      "web" => "M.headline(N.runs, Object.assign({}, M.defaultFilters(N.runs).filters, { app: 'web' }))",
      "api" => "M.headline(N.runs, Object.assign({}, M.defaultFilters(N.runs).filters, { app: 'api' }))",
      "trend" => "M.trend(N.runs, Object.assign({}, M.defaultFilters(N.runs).filters, { app: 'web' })).series[0].values.filter(function (v) { return v !== null; })",
      "matrix" => "M.latestToolkit(N.runs, Object.assign({}, M.defaultFilters(N.runs).filters, { app: 'api' })).id",
      "history" => "M.history(N).map(function (h) { return h.app; })"
    })
    assert_equal %w[api web], r["opts"]
    assert_equal "api", r["d"]["filters"]["app"]
    assert_equal [ 20.0, 0.0, "aaaaaaa" ], [ r["web"]["routes"]["value"]["pct"], r["web"]["routes"]["delta"], r["web"]["routes"]["prevSha"] ]
    assert_equal [ 90.0, 0.0 ], [ r["api"]["routes"]["value"]["pct"], r["api"]["routes"]["delta"] ]
    assert_equal 80.0, r["web"]["line"]["value"]["pct"]
    assert_equal 80.0, r["api"]["line"]["value"]["pct"]
    assert_equal [ 20.0, 20.0 ], r["trend"]
    assert_equal "bbbbbbb-run-api", r["matrix"]
    assert_equal [ "", "web", "api", "web", "api" ], r["history"]
  end

  def test_model_computes_per_family_deltas_against_the_previous_carrier
    node!
    runs = [
      run_record("r1", "2026-10-01T00:00:00Z", routes: routes(1, 4), findings: { "pass" => 1, "warn" => 0, "fail" => 5 }),
      run_record("r2", "2026-10-02T00:00:00Z", findings: { "pass" => 1, "warn" => 0, "fail" => 2 }),
      run_record("r3", "2026-10-03T00:00:00Z", routes: routes(3, 4))
    ]
    r = run_model({ "runs" => runs }, { "hl" => "M.headline(N.runs, M.defaultFilters(N.runs).filters)" })
    assert_equal 50.0, r["hl"]["routes"]["delta"]
    assert_equal "r1", r["hl"]["routes"]["prevSha"][0, 2]
    assert_equal(-3, r["hl"]["findings"]["delta"])
    assert_equal "r2", r["hl"]["findings"]["runId"]
  end

  def test_model_takes_the_imported_family_from_an_import_run_under_the_default_filter
    node!
    runs = [
      run_record("s1", "2026-10-01T00:00:00Z", routes: routes(2, 4)),
      run_record("i1", "2026-10-02T00:00:00Z", scope: "import", source: "import", imports: coverage(50, 100)),
      run_record("i2", "2026-10-03T00:00:00Z", scope: "import", source: "import", imports: coverage(812, 1040)),
      run_record("i3", "2026-10-04T00:00:00Z", branch: "feature/x", trunk: false, scope: "import", source: "import",
                 imports: coverage(1, 1))
    ]
    r = run_model({ "runs" => runs }, {
      "hl" => "M.headline(N.runs, M.defaultFilters(N.runs).filters)",
      "trend" => "M.trend(N.runs, M.defaultFilters(N.runs).filters)",
      "groups" => "M.groupsTable(N.runs, M.defaultFilters(N.runs).filters)"
    })
    line = r["hl"]["line"]
    assert_equal "i2", line["runId"]
    assert_equal 78.0, line["value"]["pct"]
    assert_equal 28.0, line["delta"]
    assert_nil r["hl"]["branch"]["value"]
    assert_equal "s1", r["hl"]["routes"]["runId"]
    assert_equal %w[s1 i1 i2], r["trend"]["points"].map { |p| p["id"] }
    assert_equal [ 50.0, nil, nil ], r["trend"]["series"][0]["values"]
    assert_equal [ nil, 50.0, 78.0 ], r["trend"]["series"][2]["values"]
    assert_equal "i2", r["groups"]["runId"]
  end

  def test_model_route_matrix_puts_unexercised_routes_first
    node!
    items = [
      { "path" => "/a", "declared" => true, "lane_status" => { "a11y" => "pass", "k6" => "lane_off" },
        "cases_static" => [], "cases_reached" => [] },
      { "path" => "/b", "declared" => true, "lane_status" => { "a11y" => "no_result", "k6" => "n_a" },
        "cases_static" => [], "cases_reached" => [] },
      { "path" => "/x", "declared" => false, "lane_status" => {}, "cases_static" => [ "s/c" ], "cases_reached" => [] }
    ]
    run = run_record("r1", "2026-10-01T00:00:00Z",
                     lanes: { "configured" => %w[k6 a11y], "ran" => %w[a11y], "results" => {} },
                     routes: { "declared_total" => 2, "declared_exercised" => 1, "items" => items })
    r = run_model({ "runs" => [ run ] }, { "m" => "M.routeMatrix(N.runs[0])" })
    m = r["m"]
    assert_equal %w[k6 a11y], m["lanes"]
    assert_equal %w[/b /a], m["rows"].map { |row| row["path"] }
    assert_equal [ "n/a", "not exercised" ], m["rows"][0]["cells"].map { |c| c["label"] }
    assert_equal [ "lane off", "pass" ], m["rows"][1]["cells"].map { |c| c["label"] }
    assert_equal [ "/x" ], m["undeclared"]
  end

  def sweep_run(sha, app, at, **families)
    run_record("#{sha}-run-#{app}", at, app: app, sweep_id: "#{at.delete('-:')[0, 15]}Z-#{sha}", **families)
  end

  def test_model_resolves_a_sweeps_imports_from_its_first_run_and_opens_on_that_app
    node!
    runs = [ sweep_run("aaaaaaa", "zeta", "2026-10-01T00:00:00Z", routes: routes(1, 2), imports: coverage(70, 100)),
             sweep_run("aaaaaaa", "alpha", "2026-10-01T00:00:00Z", routes: routes(2, 2)) ]
    r = run_model({ "runs" => runs }, {
      "d" => "M.defaultFilters(N.runs).filters.app",
      "alpha" => "M.headline(N.runs, { app: 'alpha', profile: '', branch: '', scope: '', source: '' }).line",
      "from" => "N.runs.filter(function (x) { return x.app === 'alpha'; })[0].imports_from"
    })
    assert_equal "zeta", r["d"]
    assert_equal 70.0, r["alpha"]["value"]["pct"]
    assert_equal "aaaaaaa-run-zeta", r["from"]
  end

  def test_model_deltas_skip_earlier_runs_of_the_same_commit
    node!
    runs = [
      run_record("aaaaaaa-i1", "2026-10-01T00:00:00Z", scope: "import", source: "import", imports: coverage(50, 100)),
      run_record("bbbbbbb-i1", "2026-10-02T00:00:00Z", scope: "import", source: "import", imports: coverage(60, 100)),
      run_record("bbbbbbb-i2", "2026-10-02T00:00:01Z", scope: "import", source: "import", imports: coverage(60, 100))
    ]
    r = run_model({ "runs" => runs }, {
      "line" => "M.headline(N.runs, M.defaultFilters(N.runs).filters).line",
      "first" => "M.headline(N.runs.slice(1), M.defaultFilters(N.runs).filters).line.delta"
    })
    assert_equal [ 10.0, "aaaaaaa" ], [ r["line"]["delta"], r["line"]["prevSha"] ]
    assert_nil r["first"]
  end

  def test_model_lists_failing_imported_tests_from_the_latest_carrier
    node!
    results = { "coverage" => [], "test_results" => [ {
      "label" => "vitest", "format" => "junit", "truncated" => true, "counts" => { "pass" => 9, "fail" => 1 },
      "items" => [ { "suite" => "a.test.ts", "id" => "a.test.ts#breaks", "status" => "fail", "flaky" => false, "message" => "boom" },
                   { "suite" => "b.test.ts", "id" => "b.test.ts#retried", "status" => "pass", "flaky" => true },
                   { "suite" => "c.test.ts", "id" => "c.test.ts#fine", "status" => "pass", "flaky" => false } ]
    } ] }
    green = { "coverage" => [], "test_results" => [ { "label" => "vitest", "format" => "junit", "counts" => { "pass" => 1 },
                                                     "items" => [ { "id" => "x", "status" => "pass" } ] } ] }
    runs = [ run_record("i1", "2026-10-01T00:00:00Z", scope: "import", source: "import", imports: results) ]
    r = run_model({ "runs" => runs + [ run_record("i2", "2026-10-02T00:00:00Z", scope: "import", source: "import", imports: green) ] }, {
      "old" => "M.importedFailures(N.runs.slice(0, 1), M.defaultFilters(N.runs).filters)",
      "now" => "M.importedFailures(N.runs, M.defaultFilters(N.runs).filters).rows.length",
      "none" => "M.importedFailures([], M.defaultFilters([]).filters)"
    })
    assert_equal %w[a.test.ts#breaks b.test.ts#retried], r["old"]["rows"].map { |row| row["id"] }
    assert r["old"]["truncated"]
    assert_equal [ "fail", "boom" ], r["old"]["rows"][0].values_at("status", "message")
    assert_equal 0, r["now"]
    assert_nil r["none"]
  end

  def test_model_shows_a_skipped_route_as_not_scanned_and_unexercised
    node!
    items = [ { "path" => "/a", "declared" => true, "lane_status" => { "a11y" => "not_scanned" },
                "cases_static" => [], "cases_reached" => [] } ]
    run = run_record("r1", "2026-10-01T00:00:00Z", lanes: { "configured" => %w[a11y], "ran" => %w[a11y], "results" => {} },
                     routes: { "declared_total" => 1, "declared_exercised" => 0, "items" => items })
    m = run_model({ "runs" => [ run ] }, { "m" => "M.routeMatrix(N.runs[0])" })["m"]
    assert_equal [ "not scanned" ], m["rows"][0]["cells"].map { |c| c["label"] }
    refute m["rows"][0]["exercised"]
  end

  def test_model_counts_a_lane_with_only_warnings_as_passing
    node!
    lanes = { "ran" => %w[k6 a11y zap], "results" => { "k6" => { "status" => "pass" }, "a11y" => { "status" => "warn" },
                                                        "zap" => { "status" => "fail" } } }
    r = run_model({ "runs" => [ run_record("r1", "2026-10-01T00:00:00Z", lanes: lanes) ] },
                  { "lanes" => "M.metrics.lanes(N.runs[0])" })
    assert_equal [ 2, 3 ], r["lanes"].values_at("covered", "total")
  end

  def test_model_only_links_https_pull_requests
    node!
    r = run_model({ "runs" => [] }, {
      "ok" => "M.safePrUrl({ url: 'https:' + '//example.invalid/pr/1' })",
      "js" => "M.safePrUrl({ url: 'javascript:alert(1)' })"
    })
    assert_equal "https:" + "//example.invalid/pr/1", r["ok"]
    assert_nil r["js"]
  end
end
