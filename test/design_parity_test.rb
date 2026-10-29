# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/design_parity"
require_relative "../scripts/design_tokens"

class DesignParityTest < Minitest::Test
  DRIFT = File.expand_path("fixtures/design_drift", __dir__)

  def config(areas, default: nil)
    parity = { "areas" => areas }
    parity["default"] = default if default
    DesignConfig.from_hash({ "parity" => parity })
  end

  def test_glob_matches_route_component_and_label
    c = config([ { "match" => "/checkout/*", "status" => "must_match" },
                 { "match" => "Marketing*", "status" => "intentional", "reason" => "campaign file" } ])
    assert_equal "must_match", DesignParity.classify("/checkout/pay", c).status
    assert_equal "unreviewed", DesignParity.classify("/checkout/pay/confirm", c).status
    marketing = DesignParity.classify("MarketingHero", c)
    assert_equal [ "intentional", "campaign file" ], [ marketing.status, marketing.reason ]
  end

  def test_figma_variable_names_match_with_plain_globs
    c = config([ { "match" => "color/*", "status" => "must_match" } ])
    assert_equal "must_match", DesignParity.classify("color/accent", c).status
  end

  def test_first_match_wins
    c = config([ { "match" => "/checkout", "status" => "intentional", "reason" => "beta layout" },
                 { "match" => "/check*", "status" => "must_match" } ])
    assert_equal "intentional", DesignParity.classify("/checkout", c).status
    assert_equal "must_match", DesignParity.classify("/checklist", c).status
  end

  def test_default_applies_when_nothing_matches
    assert_equal "unreviewed", DesignParity.classify("/anything", nil).status
    assert_equal "must_match", DesignParity.classify("/anything", config([], default: "must_match")).status
    assert_equal "unreviewed", DesignParity.classify(nil, config([ { "match" => "*", "status" => "must_match" } ])).status
  end

  def test_intentional_requires_reason
    assert_raises(DesignConfig::Error) { config([ { "match" => "/x", "status" => "intentional" } ]) }
    assert_raises(DesignConfig::Error) { config([ { "match" => "/x", "status" => "intentional", "reason" => "" } ]) }
  end

  def test_severity_mapping
    assert_equal "error", DesignParity.severity("must_match")
    assert_equal "info", DesignParity.severity("intentional")
    assert_equal "warning", DesignParity.severity("unreviewed")
    assert_raises(ArgumentError) { DesignParity.severity("bogus") }
    assert_equal "error", DesignParity::CANON_COPY.severity
  end

  def drift(parity, **over)
    opts = { root: DRIFT, tokens: File.join(DRIFT, "tokens.css"), screens: File.join(DRIFT, "screens_drift"),
             storyboard: File.join(DRIFT, "storyboard_match.json"), figma_snapshot: File.join(DRIFT, "figma_drift.json"),
             tailwind: false, parity: parity }.merge(over)
    DesignTokens::Drift.run(opts, compiler: ->(*) { flunk }).reject { |f| f.parity.nil? }
  end

  def test_drift_attaches_parity_and_reason
    c = config([ { "match" => "color/*", "status" => "intentional", "reason" => "brand refresh pending" } ], default: "must_match")
    figma = drift(c).find { |f| f.source == "figma" }
    assert_equal [ "info", "intentional", "brand refresh pending" ], [ figma.severity, figma.parity, figma.reason ]
    assert_equal "brand refresh pending", figma.to_h[:reason]
  end

  def test_canon_copies_are_always_must_match
    c = config([ { "match" => "*", "status" => "intentional", "reason" => "anything goes" } ], default: "intentional")
    screens = drift(c).reject { |f| f.source == "figma" }
    refute_empty screens
    assert(screens.all? { |f| f.parity == "must_match" && f.severity == "error" })
  end

  def test_cli_reads_parity_from_change_md
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "CHANGE.md"), <<~MD)
        ---
        change_config:
          design:
            parity:
              areas:
                - match: "color/*"
                  status: must_match
        ---
      MD
      out = StringIO.new
      code = DesignTokens::CLI.run([ "drift", "--root", dir, "--tokens", File.join(DRIFT, "tokens.css"),
                                     "--screens", File.join(DRIFT, "screens_match"),
                                     "--storyboard", File.join(DRIFT, "storyboard_match.json"),
                                     "--figma-snapshot", File.join(DRIFT, "figma_drift.json"), "--no-tailwind", "--json" ],
                                   out: out, err: StringIO.new)
      assert_equal 1, code
      finding = JSON.parse(out.string)["findings"].find { |f| f["source"] == "figma" }
      assert_equal [ "error", "must_match" ], finding.values_at("severity", "parity")
    end
  end
end
