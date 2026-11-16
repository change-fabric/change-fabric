# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/docs_check"
require_relative "#{SKILL_SCRIPTS}/doctrine_digest"

class DocsCheckTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  # Built from a codepoint so this file never carries the glyph it tests for.
  EM = [ 0x2014 ].pack("U")
  EXISTS = ->(path) { %w[scripts/real.rb real.rb docs].include?(path) }

  def test_the_repo_passes
    assert_equal [], DocsCheck.run(ROOT)
  end

  def test_an_unlisted_doc_fails
    problems = DocsCheck.unlisted(%w[README.md skills/x/SKILL.md docs/rca/new.md])
    assert_equal [ "docs/rca/new.md: not in the living doc allowlist (scripts/docs_check.rb)" ], problems
  end

  def test_the_shim_must_be_exactly_one_import
    assert_empty DocsCheck.shim("@AGENTS.md\n")
    refute_empty DocsCheck.shim("# Rules\n@AGENTS.md\n")
  end

  def test_over_cap_fails
    assert_empty DocsCheck.over_cap("AGENTS.md", "x\n" * 80)
    assert_equal [ "AGENTS.md: 81 lines, cap is 80" ], DocsCheck.over_cap("AGENTS.md", "x\n" * 81)
  end

  def test_a_glyph_fails_with_its_line
    assert_equal [ "PRINCIPLES.md:2: slop glyph" ], DocsCheck.glyphs("PRINCIPLES.md", "ok\nbad #{EM} here\n")
  end

  def test_a_broken_link_or_path_fails
    text = "See [x](scripts/gone.rb) and `scripts/real.rb`, `real.rb`, `missing.rb`, " \
           "`~/.claude/cf/bin/x.rb`, `skills/v1.2.3`, `cf_team_*`, [web](https://example.com)."
    problems = DocsCheck.broken_paths("ARCHITECTURE.md", text, EXISTS)
    assert_equal [ "ARCHITECTURE.md: scripts/gone.rb does not exist", "ARCHITECTURE.md: missing.rb does not exist" ],
                 problems
  end

  def test_each_principle_needs_one_real_enforcer
    text = <<~MD
      # Principles

      ## Real
      Enforcer: scripts/real.rb

      ## Advisory
      Enforcer: advisory

      ## Missing

      ## Wrong
      Enforcer: scripts/real.rb, scripts/gone.rb
    MD
    assert_equal [ "PRINCIPLES.md: \"Missing\" needs exactly one Enforcer: line",
                   "PRINCIPLES.md: \"Wrong\" enforcer scripts/gone.rb does not exist" ],
                 DocsCheck.enforcers(text, EXISTS)
  end

  # The SessionStart tenets stay a Ruby constant; this keeps each one matched to
  # the principle that states it, so neither drifts alone.
  TENET_PRINCIPLES = {
    "Containerize project services" => "## Containers, not host daemons",
    "AI-slop glyphs" => "## No slop glyphs in authored prose",
    "PR titles <= 60 chars" => "## Short PRs"
  }.freeze

  def test_every_doctrine_tenet_has_a_principle
    principles = File.read(File.join(ROOT, "PRINCIPLES.md"))
    DoctrineDigest::TENETS.each do |tenet|
      key = TENET_PRINCIPLES.keys.find { |k| tenet.include?(k) }
      refute_nil key, "tenet has no mapped principle: #{tenet[0, 60]}"
      assert_includes principles, TENET_PRINCIPLES[key]
    end
    assert_includes principles, "## No client names in this repo"
  end
end
