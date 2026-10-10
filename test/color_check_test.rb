# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../scripts/color_check"
require_relative "../scripts/change_docker"

# A canned ColorBrowser::Result stand-in so report-building logic (pairing,
# mechanism agreement, contrast, palette, rendering) can be tested without
# docker. Integration tests below exercise the real browser.
class FakeProbe
  def initialize(result, available: true)
    @result = result
    @available = available
  end

  def available? = @available

  def probe(_css)
    @result
  end
end

class ColorCheckTest < Minitest::Test
  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def rgba(r, g, b, a = 1.0) = ColorMath::Rgba.new(r:, g:, b:, a:)

  WHITE = ColorMath::WHITE
  BLACK = ColorMath::Rgba.new(r: 0, g: 0, b: 0, a: 1.0)

  def browser_result(names:, states:, declared_values: {}, classified: {}, import_error: false)
    ColorBrowser::Result.new(names:, declared_values:, classified:, states:, import_error:)
  end

  # A classified entry for a value whose one literal is the color itself.
  def authored(color, mixed: false)
    { kind: "authored", color:, literals: [ { color:, mixed: } ] }
  end

  # Every variant the same, i.e. no dark mechanism in use.
  def light_only(map)
    { light: map, class: map, attr: map, media: map }
  end

  def run_with(dir, result)
    write(dir, "tokens.css", ":root{--placeholder:#fff}") unless File.file?(File.join(dir, "tokens.css"))
    ColorCheck.run(dir, probe: FakeProbe.new(result))
  end

  # --- locate / compile-stage errors, no probe reached ---

  def test_no_token_file_is_a_token_error_not_an_exception
    with_dir do |dir|
      report = ColorCheck.run(dir)
      assert_nil report.tokens
      assert_includes report.token_errors.first.message, "no token file found"
      assert_nil report.palette
      assert_empty report.contrast
      assert_equal 0, report.exit_code
    end
  end

  def test_several_token_files_is_a_token_error
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:#fff}")
      write(dir, "src/index.css", ":root{--a:#fff}")
      report = ColorCheck.run(dir, strict: true)
      assert_includes report.token_errors.first.message, "several token files found"
      assert_equal 1, report.exit_code
    end
  end

  def test_tokens_flag_overrides_the_path_list
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:#111}")
      override = write(dir, "real.css", ":root{--background:#fff;--page-text:#000}")
      report = ColorCheck.run(dir, tokens_override: override, probe: FakeProbe.new(
        browser_result(names: %w[--background --page-text],
                        states: light_only({ "--background" => WHITE, "--page-text" => BLACK }))
      ))
      assert_equal override, report.tokens
    end
  end

  def test_missing_tailwind_install_is_a_token_error
    with_dir do |dir|
      write(dir, "tokens.css", "@theme static { --color-ink: #222; }\n:root{--a:#fff}")
      report = ColorCheck.run(dir, strict: true, probe: FakeProbe.new(nil))
      assert(report.token_errors.any? { |e| e.message.include?("install dependencies first") })
      assert_equal 1, report.exit_code
    end
  end

  # The Tailwind compile mounts only the scan root, so a --tokens file
  # outside it that needs a compile is refused with a clear message.
  def test_tokens_outside_the_root_that_needs_a_compile_is_a_token_error
    with_dir do |outside|
      override = write(outside, "tokens.css", "@theme static { --color-ink: #222; }\n:root{--a:#fff}")
      with_dir do |dir|
        write(dir, "node_modules/tailwindcss/package.json", JSON.generate({ "version" => "4.1.14" }))
        report = ColorCheck.run(dir, tokens_override: override, strict: true, probe: FakeProbe.new(nil))
        assert(report.token_errors.any? { |e| e.message.include?("outside the scan root") }, report.token_errors.inspect)
        assert_equal 1, report.exit_code
      end
    end
  end

  def test_tokens_outside_the_root_with_plain_css_reaches_the_probe
    with_dir do |outside|
      override = write(outside, "tokens.css", ":root{--background:#fff;--page-text:#000}")
      with_dir do |dir|
        report = ColorCheck.run(dir, tokens_override: override, probe: FakeProbe.new(
          browser_result(names: %w[--background --page-text],
                          states: light_only({ "--background" => WHITE, "--page-text" => BLACK }))
        ))
        assert_equal override, report.tokens
        refute(report.token_errors.any? { |e| e.message.include?("outside the scan root") })
        assert report.palette
      end
    end
  end

  # --- the report boundary never raises ---

  # A probe whose probe step raises, standing in for a browser start
  # failure, a timeout or a malformed browser reply.
  class RaisingProbe
    def initialize(error) = @error = error
    def available? = true
    def probe(_css) = raise(@error)
  end

  def test_run_never_raises
    rows = [
      [ "a missing --tokens file", "no such file",
        ->(dir) { { tokens_override: File.join(dir, "missing.css"), probe: FakeProbe.new(nil) } } ],
      [ "a directory as --tokens", "is a directory",
        ->(dir) { FileUtils.mkdir_p(File.join(dir, "styles")); { tokens_override: File.join(dir, "styles"), probe: FakeProbe.new(nil) } } ],
      [ "a probe raising RuntimeError", "could not audit: boom",
        ->(_dir) { { probe: RaisingProbe.new(RuntimeError.new("boom")) } } ],
      [ "a probe raising KeyError", "could not audit:",
        ->(_dir) { { probe: RaisingProbe.new(KeyError.new("key not found: \"names\"")) } } ],
      [ "no docker with a file that needs a compile", "Docker is required",
        lambda do |dir|
          File.write(File.join(dir, "tokens.css"), "@theme { --color-ink: #222; }\n:root{--a:#fff}")
          { probe: FakeProbe.new(nil, available: false) }
        end ]
    ]
    rows.each do |label, expected, setup|
      with_dir do |dir|
        write(dir, "tokens.css", ":root{--background:#fff}")
        report = ColorCheck.run(dir, strict: true, **setup.call(dir))
        assert_instance_of ColorCheck::Report, report, label
        assert(report.token_errors.any? { |e| e.message.include?(expected) }, "#{label}: #{report.token_errors.inspect}")
        refute(report.token_errors.any? { |e| e.message.include?("install dependencies") }, label)
        assert_equal 1, report.exit_code, label
        JSON.parse(ColorCheck.to_json_report(report))
      end
    end
  end

  # An invalid UTF-8 byte reaches the probe as raw bytes and never raises in
  # the routing scan or the JSON report.
  def test_run_never_raises_on_an_invalid_byte
    with_dir do |dir|
      File.binwrite(File.join(dir, "tokens.css"), "\xff:root{}".b)
      result = browser_result(names: [], states: light_only({}))
      report = ColorCheck.run(dir, probe: FakeProbe.new(result))
      assert_instance_of ColorCheck::Report, report
      JSON.parse(ColorCheck.to_json_report(report))
    end
  end

  # --- probe-stage conditions ---

  def test_docker_unavailable_is_a_token_error
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:#fff}")
      report = ColorCheck.run(dir, probe: FakeProbe.new(nil, available: false))
      assert(report.token_errors.any? { |e| e.message.include?("Docker is required") })
      assert_nil report.palette
    end
  end

  def test_unbundled_import_is_a_token_error
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:#fff}")
      report = run_with(dir, browser_result(names: [], states: light_only({}), import_error: true))
      assert(report.token_errors.any? { |e| e.message.include?("@import") })
    end
  end

  def test_mechanisms_disagreeing_is_a_token_error_and_no_contrast
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--background:#fff;--page-text:#000}")
      states = {
        light: { "--background" => WHITE, "--page-text" => BLACK },
        class: { "--background" => BLACK, "--page-text" => WHITE },
        attr: { "--background" => WHITE, "--page-text" => WHITE },
        media: { "--background" => BLACK, "--page-text" => WHITE }
      }
      report = run_with(dir, browser_result(names: %w[--background --page-text], states:))
      error = report.token_errors.find { |e| e.message.include?("differ at") }
      refute_nil error
      assert_includes error.message, ".dark class"
      assert_includes error.message, "data-theme attribute"
      assert_includes error.message, "--background"
      assert_empty report.contrast
    end
  end

  # --- pairing and contrast ---

  def test_contrast_pass_black_on_white
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --page-text],
                                             states: light_only({ "--background" => WHITE, "--page-text" => BLACK })))
      pair = report.contrast.find { |c| c.fg == "--page-text" }
      assert pair.resolved?
      assert_in_delta 21.0, pair.ratio, 0.01
      assert_equal "pass", pair.status
    end
  end

  def test_contrast_fails_low_contrast_pair
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --page-text],
                                             states: light_only({ "--background" => WHITE, "--page-text" => rgba(0.93, 0.93, 0.93) })))
      pair = report.contrast.find { |c| c.fg == "--page-text" }
      assert pair.resolved?
      assert_equal "fail", pair.status
    end
  end

  def test_pairing_falls_back_to_background_without_a_surface_token
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --a-text],
                                             states: light_only({ "--background" => WHITE, "--a-text" => BLACK })))
      pair = report.contrast.find { |c| c.fg == "--a-text" }
      assert_equal "--background", pair.bg
    end
  end

  def test_pairing_prefers_a_matching_surface_token
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --gold-btn --gold-btn-text],
                                             states: light_only({ "--background" => WHITE, "--gold-btn" => BLACK, "--gold-btn-text" => WHITE })))
      pair = report.contrast.find { |c| c.fg == "--gold-btn-text" }
      assert_equal "--gold-btn", pair.bg
    end
  end

  def test_unresolved_name_absent_entirely_is_not_declared
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--page-text],
                                             states: light_only({ "--page-text" => BLACK })))
      pair = report.contrast.find { |c| c.fg == "--page-text" }
      refute pair.resolved?
      assert_includes pair.reason, "--background: is not declared"
    end
  end

  def test_unresolved_name_present_but_null_in_variant_is_not_a_color
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --page-text],
                                             states: light_only({ "--background" => WHITE, "--page-text" => nil })))
      pair = report.contrast.find { |c| c.fg == "--page-text" }
      refute pair.resolved?
      assert_includes pair.reason, "--page-text: is not a color in light"
    end
  end

  def test_translucent_surface_composites_over_page_background
    with_dir do |dir|
      report = run_with(dir, browser_result(
        names: %w[--background --card --card-text],
        states: light_only({ "--background" => BLACK, "--card" => rgba(0, 0, 0, 0.5), "--card-text" => BLACK })
      ))
      pair = report.contrast.find { |c| c.fg == "--card-text" }
      assert pair.resolved?
      assert_in_delta 1.0, pair.ratio, 0.01
    end
  end

  def test_translucent_surface_with_unresolvable_backdrop_is_unresolved
    with_dir do |dir|
      report = run_with(dir, browser_result(
        names: %w[--background --card --card-text],
        states: light_only({ "--background" => nil, "--card" => rgba(0, 0, 0, 0.5), "--card-text" => BLACK })
      ))
      pair = report.contrast.find { |c| c.fg == "--card-text" }
      refute pair.resolved?
      assert_includes pair.reason, "--background"
    end
  end

  def test_dark_variant_contrast_row_appears_only_when_a_mechanism_is_in_use
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --page-text],
                                             states: light_only({ "--background" => WHITE, "--page-text" => BLACK })))
      refute(report.contrast.any? { |c| c.variant == "dark" })
    end

    with_dir do |dir|
      states = { light: { "--background" => WHITE, "--page-text" => BLACK },
                 class: { "--background" => BLACK, "--page-text" => WHITE },
                 attr: { "--background" => BLACK, "--page-text" => WHITE },
                 media: { "--background" => BLACK, "--page-text" => WHITE } }
      report = run_with(dir, browser_result(names: %w[--background --page-text], states:))
      dark = report.contrast.find { |c| c.variant == "dark" && c.fg == "--page-text" }
      refute_nil dark
      assert_in_delta 21.0, dark.ratio, 0.01
    end
  end

  def test_no_pairs_declared_reports_no_contrast_rows
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--brand], states: light_only({ "--brand" => BLACK })))
      assert_empty report.contrast
      assert_includes ColorCheck.render(report), "none declared"
    end
  end

  # --- palette ---

  def test_authored_colors_grouped_by_resolved_color_with_declaring_names
    with_dir do |dir|
      declared_values = { "--cream" => [ "#f6efe0" ], "--same-color" => [ "rgb(246, 239, 224)" ] }
      classified = {
        "#f6efe0" => authored(rgba(0.9647, 0.9373, 0.8784)),
        "rgb(246, 239, 224)" => authored(rgba(0.9647, 0.9373, 0.8784))
      }
      report = run_with(dir, browser_result(names: %w[--cream --same-color], states: light_only({}),
                                             declared_values:, classified:))
      assert_equal 1, report.palette.authored.size
      assert_equal %w[--cream --same-color].sort, report.palette.authored.first[:names].sort
    end
  end

  def test_error_token_excluded_from_authored_count_but_flagged
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--error:red}")
      declared_values = { "--error" => [ "red" ] }
      classified = { "red" => authored(rgba(1, 0, 0)) }
      report = run_with(dir, browser_result(names: %w[--error], states: light_only({}),
                                             declared_values:, classified:))
      assert_empty report.palette.authored
      assert report.palette.error_token
    end
  end

  def test_derived_declarations_are_counted_not_listed_as_authored
    with_dir do |dir|
      declared_values = { "--muted" => [ "color-mix(in srgb, var(--a) 60%, var(--b))" ] }
      classified = { "color-mix(in srgb, var(--a) 60%, var(--b))" => { kind: "derived", color: rgba(0.5, 0.5, 0.5), literals: [] } }
      report = run_with(dir, browser_result(names: %w[--muted], states: light_only({}),
                                             declared_values:, classified:))
      assert_empty report.palette.authored
      assert_equal 1, report.palette.derived
    end
  end

  # D3: a literal found inside a mix counts at full opacity and merges with
  # the same literal declared on its own.
  def test_mixed_literal_counts_opaque_and_merges
    with_dir do |dir|
      mix = "color-mix(in srgb, var(--background), #ff0000)"
      declared_values = { "--red" => [ "#ff0000" ], "--x" => [ mix ] }
      classified = {
        "#ff0000" => authored(rgba(1, 0, 0)),
        mix => { kind: "authored", color: rgba(1, 0.5, 0.5),
                 literals: [ { color: rgba(1, 0, 0, 0.5), mixed: true } ] }
      }
      report = run_with(dir, browser_result(names: %w[--red --x], states: light_only({}),
                                             declared_values:, classified:))
      assert_equal 1, report.palette.authored.size
      assert_equal %w[--red --x], report.palette.authored.first[:names]
    end
  end

  # P2: a fully transparent literal is not a color.
  def test_transparent_literal_is_not_counted
    with_dir do |dir|
      declared_values = { "--clear" => [ "#ff000000" ] }
      classified = { "#ff000000" => authored(rgba(1, 0, 0, 0)) }
      report = run_with(dir, browser_result(names: %w[--clear], states: light_only({}),
                                             declared_values:, classified:))
      assert_empty report.palette.authored
    end
  end

  # A larger palette is reported as distance from target, never as an
  # error: the skill is advisory and --strict must not fail on it.
  def test_palette_above_target_is_not_an_error
    with_dir do |dir|
      # Five distinct colors, one declared value each so each groups alone.
      names = (1..5).map { |i| "--c#{i}" }
      declared_values = names.each_with_index.to_h { |n, i| [ n, [ "#color#{i}" ] ] }
      classified = names.each_with_index.to_h { |n, i| [ "#color#{i}", authored(rgba(i / 10.0, 0, 0)) ] }
      write(dir, "tokens.css", names.map { |n| ":root{#{n}:#000}" }.join)
      report = ColorCheck.run(dir, strict: true,
                                   probe: FakeProbe.new(browser_result(names:, states: light_only({}),
                                                                       declared_values:, classified:)))
      assert_equal 5, report.palette.authored.size
      assert_empty report.token_errors
      assert_equal 0, report.exit_code
    end
  end

  # --- rendering / JSON / exit codes ---

  def test_strict_exits_one_on_token_error_and_zero_without
    with_dir do |dir|
      write(dir, "tokens.css", "@theme static { --x: #fff; }")
      assert_equal 1, ColorCheck.run(dir, strict: true, probe: FakeProbe.new(nil)).exit_code
      assert_equal 0, ColorCheck.run(dir, strict: false, probe: FakeProbe.new(nil)).exit_code
    end
  end

  def test_strict_exits_one_on_failing_contrast
    with_dir do |dir|
      result = browser_result(names: %w[--background --page-text],
                               states: light_only({ "--background" => WHITE, "--page-text" => rgba(0.95, 0.95, 0.95) }))
      write(dir, "tokens.css", ":root{--placeholder:#fff}")
      report = ColorCheck.run(dir, strict: true, probe: FakeProbe.new(result))
      assert_equal 1, report.exit_code
    end
  end

  def test_json_output_shape
    with_dir do |dir|
      report = run_with(dir, browser_result(names: %w[--background --page-text],
                                             states: light_only({ "--background" => WHITE, "--page-text" => BLACK })))
      parsed = JSON.parse(ColorCheck.to_json_report(report))
      assert_equal %w[tokens token_errors palette contrast exit_code], parsed.keys
      assert_equal %w[variant fg bg ratio status reason], parsed["contrast"].first.keys
    end
  end

  def test_shown_ratio_floors_instead_of_rounding_across_a_threshold
    assert_equal 2.99, ColorCheck.shown_ratio(2.999)
    assert_equal "fail", ColorCheck.status_for(2.999)
    assert_equal 4.49, ColorCheck.shown_ratio(4.499)
    assert_equal "large-only", ColorCheck.status_for(4.499)
  end

  # --- CLI ---

  def test_cli_rejects_malformed_command_lines
    [
      [ %w[--tokens --strict], "--tokens needs a path" ],
      [ %w[--tokens], "--tokens needs a path" ],
      [ %w[. --strcit], "unknown option --strcit" ],
      [ %w[repo-a repo-b --strict], "second repo root repo-b" ],
      [ %w[--tokens a.css --tokens b.css], "--tokens given twice" ]
    ].each do |argv, message|
      out = StringIO.new
      _, err = capture_io do
        error = assert_raises(SystemExit) { ColorCheck::CLI.run(argv, out:) }
        assert_equal 2, error.status, argv.inspect
      end
      assert_includes err, message, argv.inspect
      assert_empty out.string, argv.inspect
    end
  end
end

# Real-browser regression corpus: every row runs the actual Chromium probe
# through ChangeDocker, covering the PR #245 review cases that sank the
# hand-written CSS parser. Skips only when docker itself is unavailable.
class ColorCheckIntegrationTest < Minitest::Test
  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def run_css(css)
    with_dir do |dir|
      write(dir, "tokens.css", css)
      return ColorCheck.run(dir)
    end
  end

  def test_important_light_beats_normal_dark_override
    report = run_css(":root{--background:#fff !important;--page-text:#000}\n" \
                      ".dark{--background:#000;--page-text:#fff}")
    pair = report.contrast.find { |c| c.variant == "dark" && c.fg == "--page-text" }
    # background stays white in dark (important wins), page-text goes white:
    # white on white, 1:1, fails.
    assert_in_delta 1.0, pair.ratio, 0.01
    assert_equal "fail", pair.status
  end

  def test_oklch_and_color_mix_resolve_to_real_colors
    report = run_css(":root{--background:oklch(1 0 0);--page-text:color-mix(in srgb, black 100%, white 0%)}")
    pair = report.contrast.find { |c| c.fg == "--page-text" }
    assert pair.resolved?
    assert_in_delta 21.0, pair.ratio, 0.01
  end

  def test_var_fallback_used_when_referenced_token_is_initial
    report = run_css(":root{--kw:initial;--background:#fff;--page-text:var(--kw, red)}")
    pair = report.contrast.find { |c| c.fg == "--page-text" }
    assert pair.resolved?
    assert_in_delta 4.0, pair.ratio, 0.05
  end

  def test_invalid_byte_never_raises_through_the_browser
    with_dir do |dir|
      File.binwrite(File.join(dir, "tokens.css"), "\xff:root{}".b)
      report = ColorCheck.run(dir)
      assert_instance_of ColorCheck::Report, report
      JSON.parse(ColorCheck.to_json_report(report))
    end
  end

  # The browser's TextDecoder strips a UTF-8 BOM, so it never becomes part
  # of the first selector and every pair still resolves.
  def test_utf8_bom_is_stripped_by_the_browser
    with_dir do |dir|
      File.binwrite(File.join(dir, "tokens.css"), "\xEF\xBB\xBF:root{--background:#fff;--page-text:#000}".b)
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.fg == "--page-text" }
      assert pair&.resolved?, report.contrast.inspect
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_bad_bang_token_is_dropped_by_the_browser
    report = run_css(":root{--background:#fff;--page-text: black ! foo}")
    assert_empty report.token_errors
    refute(report.contrast.any? { |c| c.fg == "--page-text" })
  end

  def test_unquoted_url_with_a_quote_is_dropped
    report = run_css(%(:root{--background:#fff;--page-text:url(foo"bar)}))
    assert_empty report.token_errors
    refute(report.contrast.any? { |c| c.fg == "--page-text" })
  end

  # A "--name:" inside a string or a style query is not a declaration; with
  # no Ruby text scan it can never read as a dropped one.
  def test_names_in_strings_and_style_queries_are_not_errors
    with_dir do |dir|
      write(dir, "tokens.css", %(:root{--background:#fff;--page-text:#000;--note:"--ghost: 1"}\n) +
                               "@container style(--theme: dark){:root{--page-text:#000}}")
      report = ColorCheck.run(dir, strict: true)
      assert_empty report.token_errors
      assert_equal 0, report.exit_code
    end
  end

  def test_error_token_inside_a_string_is_not_present
    report = run_css(%(:root{--background:#fff;--note:"--error: x"}))
    assert_equal false, report.palette.error_token
  end

  def test_declared_error_token_is_present
    report = run_css(":root{--error:#c00}")
    assert_equal true, report.palette.error_token
  end

  def test_escaped_name_is_the_plain_name
    report = run_css(":root{--\\61 :#fff;--background:var(--a)}")
    assert_empty report.token_errors.map(&:message)
  end

  def test_escaped_hash_is_not_a_color
    report = run_css(":root{--background:#fff;--page-text:\\#eee}")
    pair = report.contrast.find { |c| c.fg == "--page-text" }
    refute pair.resolved?
  end

  def test_layered_dark_override_loses_to_unlayered_light
    report = run_css("@layer base{.dark{--background:#000}}\n:root{--background:#fff;--page-text:#000}\n.dark{--page-text:#fff}")
    pair = report.contrast.find { |c| c.variant == "dark" && c.fg == "--page-text" }
    assert_in_delta 1.0, pair.ratio, 0.01
    assert_equal "fail", pair.status
  end

  def test_root_dot_dark_specificity
    report = run_css(":root{--background:#fff;--page-text:#000}\n:root.dark{--background:#000;--page-text:#fff}")
    pair = report.contrast.find { |c| c.variant == "dark" && c.fg == "--page-text" }
    assert_in_delta 21.0, pair.ratio, 0.01
    assert_equal "pass", pair.status
  end

  def test_prefers_color_scheme_dark_media
    report = run_css(":root{--background:#fff;--page-text:#000}\n" \
                      "@media (prefers-color-scheme: dark){:root{--background:#000;--page-text:#fff}}")
    pair = report.contrast.find { |c| c.variant == "dark" && c.fg == "--page-text" }
    assert_in_delta 21.0, pair.ratio, 0.01
  end

  def test_html_dot_dark_selector_is_honored_by_the_browser
    report = run_css("html{--background:#fff;--page-text:#000}\nhtml.dark{--background:#000;--page-text:#fff}")
    pair = report.contrast.find { |c| c.variant == "dark" && c.fg == "--page-text" }
    refute_nil pair
    assert pair.resolved?
  end

  def test_mismatched_mechanisms_is_a_token_error
    report = run_css(":root{--background:#fff;--page-text:#000}\n" \
                      ".dark{--background:#000}\n[data-theme=dark]{--page-text:#fff}")
    assert(report.token_errors.any? { |e| e.message.include?("differ at") })
    assert_empty report.contrast
  end

  # Each row: declared value of --x, extra declarations, expected kind, and
  # the expected literals as [r, g, b, a, mixed].
  RED = [ 1, 0, 0, 1, false ].freeze
  CLASSIFY_CORPUS = [
    [ "color-mix(in srgb, var(--brand), #ff0000)", "", "authored", [ [ 1, 0, 0, 0.5, true ] ] ],
    [ "var(--missing, #f00)", "", "authored", [ RED ] ],
    [ "var(--missing, var(--missing2, #f00))", "", "authored", [ RED ] ],
    [ "var(--a, #f00)", "", "derived", [] ],
    [ "var(--a, var(--b, #f00))", "", "derived", [] ],
    [ "color-mix(in srgb, var(--a) 100%, #f00 0%)", "", "derived", [] ],
    [ "color-mix(in srgb, var(--a) 12%, transparent)", "", "derived", [] ],
    [ "color-mix(in srgb, var(--a) 60%, var(--b))", "", "derived", [] ],
    [ "color-mix(in srgb, var(--a), #ff000080)", "", "authored", [ [ 1, 0, 0, 0.25, true ] ] ],
    [ "rgb(from var(--a) r g b / 0.5)", "", "derived", [] ],
    [ "light-dark(var(--a), #fff)", "", "authored", [ [ 1, 1, 1, 1, false ] ] ],
    [ "light-dark(#000, #fff)", "", "authored", [ [ 0, 0, 0, 1, false ], [ 1, 1, 1, 1, false ] ] ],
    [ "color-mix(in srgb, currentColor, #f00)", "", "authored", [ [ 1, 0, 0, 0.5, true ] ] ],
    [ "transparent", "", nil, [] ],
    [ "#ff000000", "", nil, [] ],
    [ "v\\61r(--a)", "", "derived", [] ],
    [ "var(--kw, red)", ":root{--kw:initial}", "authored", [ RED ] ],
    [ "var(--accent, #0ff)", ".dark{--accent:#123}", "authored", [ [ 0, 1, 1, 1, false ] ] ]
  ].freeze

  def test_classification_corpus
    css = ":root{--brand:#123456;--a:#0000ff;--b:#00ff00;" +
          CLASSIFY_CORPUS.each_with_index.map { |(value, _), i| "--x#{i}:#{value}" }.join(";") + "}\n" +
          CLASSIFY_CORPUS.map { |row| row[1] }.uniq.join("\n")
    probed = ColorBrowser.probe(css)
    CLASSIFY_CORPUS.each_with_index do |(_, _, kind, literals), i|
      value = probed.declared_values.fetch("--x#{i}").first
      entry = probed.classified.fetch(value)
      label = "#{value}: #{entry.inspect}"
      kind.nil? ? assert_nil(entry[:kind], label) : assert_equal(kind, entry[:kind], label)
      assert_equal literals.size, entry[:literals].size, label
      literals.zip(entry[:literals]).each do |(r, g, b, a, mixed), got|
        [ r, g, b, a ].zip([ got[:color].r, got[:color].g, got[:color].b, got[:color].a ]).each do |want, have|
          assert_in_delta want, have, 0.01, label
        end
        assert_equal mixed, got[:mixed], label
      end
    end
  end

  # D3 through the real browser: the red inside the mix merges with --red.
  def test_mixed_literal_merges_with_the_same_literal
    report = run_css(":root{--background:#fff;--red:#ff0000;--x:color-mix(in srgb, var(--background), #ff0000)}")
    assert_equal 2, report.palette.authored.size, report.palette.authored.inspect
    red = report.palette.authored.find { |a| a[:names].include?("--red") }
    assert_equal %w[--red --x], red[:names]
  end

  # P2 through the real browser: transparent is not an authored color.
  def test_transparent_is_not_an_authored_color
    report = run_css(":root{--background:#fff;--page-text:#000;--clear:transparent}")
    assert_equal 2, report.palette.authored.size, report.palette.authored.inspect
  end

  def test_reference_example_palette_passes_the_checker
    css = File.read(File.expand_path("../skills/color/reference/example-palette.md", __dir__))[/```css\n(.*?)```/m, 1]
    refute_nil css, "example-palette.md has no css block"
    with_dir do |dir|
      write(dir, "tokens.css", css)
      report = ColorCheck.run(dir, strict: true)
      assert_empty report.token_errors.map(&:message)
      assert_equal 0, report.exit_code
      rows = report.contrast.map { |c| [ c.variant, c.fg, c.bg ] }
      %w[light dark].product(%w[--page-text --accent-ink --title-text]).each do |variant, fg|
        assert_includes rows, [ variant, fg, "--background" ]
      end
      assert(report.contrast.all?(&:resolved?))
      assert_equal 4, report.palette.authored.size, report.palette.authored.inspect
    end
  end
end

# Gated additionally on network/npm: installs tailwindcss into a throwaway
# node_modules inside the pinned node container (never on the host), then
# runs the real compile path.
class ColorCheckTailwindIntegrationTest < Minitest::Test
  TAILWIND_VERSION = "4.1.14"

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def npm_install(dir)
    argv = ChangeDocker.run_command(
      network: nil, image: ChangeDocker::NODE_IMAGE,
      args: [ "npm", "i", "--no-save", "tailwindcss@#{TAILWIND_VERSION}" ],
      env: { "HOME" => "/tmp", "npm_config_update_notifier" => "false" },
      mounts: { dir => "/repo" }, user: "#{Process.uid}:#{Process.gid}", workdir: "/repo"
    )
    Open3.capture2e(*argv)
  end

  def test_theme_static_reset_and_inlined_local_import_compile_through_tailwind
    with_dir do |dir|
      _out, status = npm_install(dir)
      skip "no network/npm access for tailwindcss install" unless status.success?

      write(dir, "extra.css", ":root{--from-import:#abcdef}")
      write(dir, "tokens.css", <<~CSS)
        @import "tailwindcss";
        @import "./extra.css";
        @theme { --color-brand: #123456; --color-*: initial; }
        @theme static { --color-ink: #222; --background: #fff; --page-text: var(--color-ink); }
      CSS
      report = ColorCheck.run(dir)
      refute(report.token_errors.any? { |e| e.message.include?("install dependencies") }, report.token_errors.inspect)
      refute(report.token_errors.any? { |e| e.message.include?("@import") }, report.token_errors.inspect)
      assert report.palette
      pair = report.contrast.find { |c| c.fg == "--page-text" }
      refute_nil pair
      assert pair.resolved?
    end
  end
end
