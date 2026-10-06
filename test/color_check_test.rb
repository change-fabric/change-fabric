# frozen_string_literal: true

require_relative 'test_helpers'
require_relative "#{File.expand_path('../scripts', __dir__)}/color_check"

class ColorCheckTest < Minitest::Test
  include SkillTempHome

  def with_dir
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  FOUR_COLOR_TOKENS = <<~CSS
    :root,
    :root[data-theme="light"] {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --pink: #f2c4c4;
      --bg: var(--cream);
      --text: var(--plum);
    }

    :root[data-theme="dark"] {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --pink: #f2c4c4;
      --bg: var(--plum);
      --text: var(--cream);
    }
  CSS

  def test_four_authored_colors_reassigned_across_themes_count_as_four
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_equal 4, report.palette.authored.size
    end
  end

  def test_error_token_recognised_and_excluded_sixth_color_reported_above_target
    with_dir do |dir|
      css = FOUR_COLOR_TOKENS.sub('--pink: #f2c4c4;', "--pink: #f2c4c4;\n  --error: #ff0000;\n  --extra: #123456;")
      write(dir, 'tokens.css', css)
      report = ColorCheck.run(dir)
      assert report.palette.error_token
      assert_equal 5, report.palette.authored.size
      refute report.palette.authored.any? { |a| a[:names].include?('--error') }
    end
  end

  def test_color_mix_and_var_values_count_as_derived
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      assert_operator report.palette.derived, :>, 0
    end
  end

  def test_literal_colors_in_component_file_reported_with_file_and_line
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      write(dir, 'src/Button.jsx', <<~JSX)
        const a = "#ff0000";
        const b = "rgb(1,2,3)";
        const c = "hsl(0, 0%, 0%)";
        const d = "oklch(0.5 0.1 90)";
      JSX
      report = ColorCheck.run(dir)
      literal_findings = report.findings.select { |f| f.kind == 'literal' }
      assert_equal 4, literal_findings.size
      assert literal_findings.all? { |f| f.file.end_with?('Button.jsx') }
      assert_equal [1, 2, 3, 4], literal_findings.map(&:line).sort
    end
  end

  def test_tailwind_classes_reported_and_semantic_class_not_reported
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      write(dir, 'src/Card.jsx', <<~JSX)
        <div className="bg-slate-100 text-blue-600 bg-primary">hi</div>
      JSX
      report = ColorCheck.run(dir)
      tailwind_findings = report.findings.select { |f| f.kind == 'tailwind' }
      matches = tailwind_findings.flat_map { |f| f.text.scan(ColorCheck::TAILWIND) }
      assert_includes matches, 'bg-slate-100'
      assert_includes matches, 'text-blue-600'
      refute_includes matches, 'bg-primary'
    end
  end

  def test_gradient_reported
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      write(dir, 'src/hero.css', '.hero { background: linear-gradient(to right, red, blue); }')
      report = ColorCheck.run(dir)
      assert report.findings.any? { |f| f.kind == 'gradient' }
    end
  end

  def test_node_modules_and_dist_are_skipped
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      write(dir, 'node_modules/pkg/index.css', '.x { color: #ff0000; }')
      write(dir, 'dist/bundle.css', '.y { color: #00ff00; }')
      report = ColorCheck.run(dir)
      assert report.findings.none? { |f| f.file.include?('node_modules') }
      assert report.findings.none? { |f| f.file.include?('/dist/') }
    end
  end

  def test_tokens_flag_overrides_detection
    with_dir do |dir|
      write(dir, 'decoy.css', ':root { --a: #111111; --b: #222222; --c: #333333; --d: #444444; --e: #555555; }')
      override_path = write(dir, 'real-tokens.css', FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir, tokens_override: override_path)
      assert_equal override_path, report.palette.file
      assert_equal 4, report.palette.authored.size
    end
  end

  def test_default_exit_is_zero_even_with_findings
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      write(dir, 'src/Button.jsx', 'const a = "#ff0000";')
      report = ColorCheck.run(dir, strict: false)
      assert_equal 0, report.exit_code
    end
  end

  def test_strict_exits_one_with_findings_and_zero_without
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      write(dir, 'src/Button.jsx', 'const a = "#ff0000";')
      with_findings = ColorCheck.run(dir, strict: true)
      assert_equal 1, with_findings.exit_code
    end

    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      without_findings = ColorCheck.run(dir, strict: true)
      assert_equal 0, without_findings.exit_code
    end
  end

  def test_contrast_black_on_white_is_21
    with_dir do |dir|
      write(dir, 'tokens.css', <<~CSS)
        :root {
          --bg: #ffffff;
          --text: #000000;
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == '--text' }
      refute_nil pair
      assert pair.resolved
      assert_in_delta 21.0, pair.ratio, 0.01
    end
  end

  def test_contrast_color_mix_pair_resolves
    with_dir do |dir|
      write(dir, 'tokens.css', <<~CSS)
        :root {
          --bg: #ffffff;
          --plum: #24122a;
          --text: color-mix(in srgb, var(--plum) 100%, transparent);
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == '--text' }
      refute_nil pair
      assert pair.resolved
    end
  end

  def test_contrast_unresolvable_pair_listed_as_unresolved
    with_dir do |dir|
      write(dir, 'tokens.css', <<~CSS)
        :root {
          --bg: #ffffff;
          --text: oklch(0.5 0.1 90);
        }
      CSS
      report = ColorCheck.run(dir)
      pair = report.contrast.find { |c| c.text_token == '--text' }
      refute_nil pair
      refute pair.resolved
    end
  end

  def test_json_output_parses
    with_dir do |dir|
      write(dir, 'tokens.css', FOUR_COLOR_TOKENS)
      report = ColorCheck.run(dir)
      parsed = JSON.parse(ColorCheck.to_json_report(report))
      assert parsed.key?('palette')
      assert parsed.key?('findings')
      assert parsed.key?('contrast')
      assert parsed.key?('exit_code')
    end
  end

  def test_empty_directory_reports_no_palette_found_and_exits_zero
    with_dir do |dir|
      report = ColorCheck.run(dir)
      assert_nil report.palette
      assert_equal 0, report.exit_code
      assert_includes ColorCheck.render(report), 'no palette found'
    end
  end
end
