# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/design_tokens"

class DesignTokensTest < Minitest::Test
  TOKENS = <<~CSS
    :root {
      --bg: #ffffff;
      --text: #1a1a1a;
      --accent: #0a5cff;
    }
  CSS

  def doc(extra = "")
    sections = DesignTokens::REQUIRED_SECTIONS.map do |name|
      "## #{name}\n\nA line about #{name.downcase}. [assumption]\n"
    end
    "# Design\n\n#{sections.join("\n")}#{extra}"
  end

  def test_css_fences_extracts_only_css_blocks
    md = "x\n```css\n--a: 1;\n```\n```ruby\nputs 1\n```\n```css\n--b: 2;\n```\n"
    assert_equal [ "--a: 1;", "--b: 2;" ], DesignTokens.css_fences(md)
  end

  def test_verbatim_check_reports_misses
    md = "```css\n:root {\n  --bg: #ffffff;\n  --text: #000000;\n}\n```\n"
    assert_equal [ "--text: #000000;" ], DesignTokens.verbatim_check(md, TOKENS)
  end

  def test_verbatim_check_clean_when_all_present
    md = "```css\n--accent: #0a5cff;\n```\n"
    assert_empty DesignTokens.verbatim_check(md, TOKENS)
  end

  def test_required_sections_flags_missing
    md = doc.sub("## Themes\n", "## Theming\n")
    findings = DesignTokens.required_sections(md)
    assert_equal [ "missing section: ## Themes" ], findings.map(&:message)
  end

  def test_required_sections_ignores_headings_inside_fences
    md = doc.sub("## Components\n", "```md\n## Components\n```\n")
    assert_equal 1, DesignTokens.required_sections(md).size
  end

  def test_provenance_lint_clean_document
    assert_empty DesignTokens.provenance_lint(doc)
  end

  def test_provenance_lint_flags_untagged_line_in_scope
    md = doc.sub("A line about principles. [assumption]", "Calm over clever.")
    findings = DesignTokens.provenance_lint(md)
    assert_equal 1, findings.size
    assert_match(/Principles/, findings.first.message)
  end

  def test_provenance_lint_accepts_evidence_and_proposal_tags
    md = doc.sub("[assumption]", "[evidence: prd.md#goals]").sub("[assumption]", "[proposal]")
    assert_empty DesignTokens.provenance_lint(md)
  end

  def test_provenance_lint_rejects_evidence_without_anchor
    md = doc.sub("A line about principles. [assumption]", "Calm. [evidence: prd.md]")
    assert_equal 1, DesignTokens.provenance_lint(md).size
  end

  def test_provenance_lint_exempts_out_of_scope_sections_fences_and_table_headers
    table = "| Role | Token |\n|---|---|\n| page | --bg [proposal] |\n"
    md = doc
      .sub("A line about problem and users. [assumption]", "Untagged is fine here.")
      .sub("A line about open questions. [assumption]", "Also fine.")
      .sub("## Tokens\n", "## Tokens\n\n#{table}\n```css\n--bg: #ffffff;\n```\n")
    assert_empty DesignTokens.provenance_lint(md)
  end

  def test_provenance_lint_flags_untagged_table_body_row
    md = doc.sub("## Tokens\n", "## Tokens\n\n| Role | Token |\n|---|---|\n| page | --bg |\n")
    assert_equal 1, DesignTokens.provenance_lint(md).size
  end

  def test_contrast_argv_targets_color_check_json
    argv = DesignTokens.contrast_argv("tokens.css", bin: "/bin/color_check.rb")
    assert_equal [ RbConfig.ruby, "/bin/color_check.rb", "--tokens", "tokens.css", "--json" ], argv
  end

  def test_contrast_parses_stubbed_report_and_flags_failures
    seen = nil
    report = { contrast: [
      { variant: "light", fg: "--text", bg: "--bg", ratio: 15.2, status: "pass", reason: nil },
      { variant: "dark", fg: "--muted", bg: "--bg", ratio: 2.1, status: "fail", reason: nil }
    ] }
    runner = lambda do |argv|
      seen = argv
      [ JSON.generate(report), "", nil ]
    end
    parsed = DesignTokens.contrast("t.css", bin: "/x/color_check.rb", runner: runner)
    assert_equal "--json", seen.last
    findings = DesignTokens.contrast_findings(parsed)
    assert_equal 1, findings.size
    assert_match(/dark: --muted on --bg is 2.1/, findings.first.message)
  end

  def test_contrast_raises_named_message_on_non_json
    runner = ->(_argv) { [ "", "docker not found", nil ] }
    error = assert_raises(RuntimeError) { DesignTokens.contrast("t.css", runner: runner) }
    assert_match(/docker not found/, error.message)
  end

  def test_cli_exit_codes
    Dir.mktmpdir do |dir|
      tokens = File.join(dir, "tokens.css")
      design = File.join(dir, "DESIGN.md")
      File.write(tokens, TOKENS)
      File.write(design, doc)
      out = StringIO.new
      assert_equal 0, DesignTokens::CLI.run([ "lint", design, tokens ], out: out)
      assert_match(/clean/, out.string)

      File.write(design, doc("```css\n--nope: 1px;\n```\n"))
      out = StringIO.new
      assert_equal 1, DesignTokens::CLI.run([ "lint", design, tokens, "--json" ], out: out)
      assert_equal "verbatim", JSON.parse(out.string)["findings"].first["kind"]

      assert_equal 2, DesignTokens::CLI.run([ "check" ], out: StringIO.new, err: StringIO.new)
    end
  end
end
