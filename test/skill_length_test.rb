#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Enforces the mechanically-checkable rules Anthropic publishes for SKILL.md in
# "Skill authoring best practices" (platform.claude.com/docs/en/agents-and-tools/
# agent-skills/best-practices). Each is checked in the unit the doc states:
#
#   - body:        under 500 lines  ("Keep SKILL.md body under 500 lines")
#   - name:        <= 64 chars, lowercase/numbers/hyphens, no reserved words
#   - description: non-empty, <= 1024 chars, third person
#
# A skill nearing the body limit gets a GitHub Actions warning (no failure) so it
# can be split before it blows the budget. The qualitative best practices
# (conciseness, progressive disclosure, consistent terminology) stay judgment
# calls; only what a regex can settle authoritatively lives here.
#
# Lines is the documented metric for the body and what we gate on. It is gameable
# by packing many words onto one line, but a SKILL.md authored that way fails the
# rubocop/glyph passes and review long before it reaches here, so a second
# token/word budget would be an unsourced "voodoo constant". When Anthropic
# publishes a token figure, add it here.
class SkillLengthTest < Minitest::Test
  REPO_SKILLS = File.expand_path("../skills", __dir__)

  MAX_BODY_LINES = 500
  WARN_BODY_LINES = 400
  MAX_NAME_CHARS = 64
  MAX_DESCRIPTION_CHARS = 1024

  # Lowercase letters, numbers, and hyphens, with an optional `namespace:` prefix
  # (this repo namespaces every skill as `pst:<slug>`).
  NAME_PATTERN = /\A[a-z0-9-]+(?::[a-z0-9-]+)?\z/
  RESERVED_NAME_WORDS = %w[anthropic claude].freeze

  # First/second-person tells. Anthropic injects the description into the system
  # prompt and warns that mixed point-of-view hurts discovery, so it must read in
  # third person. These target the openers and stock phrases the doc calls out
  # ("I can help you...", "You can use this to...") without tripping referential
  # use like "everything you author".
  NON_THIRD_PERSON = [
    [ /\A(I|We|You)\b/, "opens in first or second person" ],
    [ /\bI'?(ll|m|ve)\b/i, "uses a first-person contraction" ],
    [ /\bI (can|will|help)\b/i, "speaks as 'I'" ],
    [ /\byou can use this\b/i, "addresses the reader as 'you'" ],
    [ /\blet me\b/i, "speaks as 'me'" ]
  ].freeze

  def skill_files
    Dir.glob(File.join(REPO_SKILLS, "*", "SKILL.md")).sort
  end

  # Returns [frontmatter_hash, body_string] for a SKILL.md, splitting on the
  # leading `---` fenced YAML block.
  def parse(path)
    text = File.read(path)
    match = text.match(/\A---\n(?<front>.*?)\n---\n(?<body>.*)\z/m)
    refute_nil match, "#{rel(path)}: missing YAML frontmatter fenced by ---"
    [ YAML.safe_load(match[:front]), match[:body] ]
  end

  def rel(path)
    path.delete_prefix("#{File.dirname(REPO_SKILLS)}/")
  end

  # Yields [frontmatter_hash, body_string, relative_path] for every shipped skill.
  def each_skill
    skill_files.each do |path|
      front, body = parse(path)
      yield front, body, rel(path)
    end
  end

  def test_every_skill_has_a_skill_file
    refute_empty skill_files, "no skills/*/SKILL.md found"
  end

  def test_body_under_500_lines
    each_skill do |_, body, rel|
      lines = body.lines.count
      assert_operator lines, :<=, MAX_BODY_LINES,
                      "#{rel}: body is #{lines} lines, over the #{MAX_BODY_LINES}-line budget. " \
                      "Split detail into reference files (progressive disclosure)."
      warn_near_limit(rel, lines) if lines >= WARN_BODY_LINES
    end
  end

  def test_name_within_64_chars
    each_skill do |front, _, rel|
      name = front["name"].to_s
      assert_operator name.length, :<=, MAX_NAME_CHARS,
                      "#{rel}: name is #{name.length} chars, over the #{MAX_NAME_CHARS}-char limit."
    end
  end

  def test_name_is_well_formed
    each_skill do |front, _, rel|
      name = front["name"].to_s
      assert_match NAME_PATTERN, name,
                   "#{rel}: name '#{name}' must be lowercase letters, numbers, and hyphens, " \
                   "with an optional 'namespace:' prefix."
      RESERVED_NAME_WORDS.each do |word|
        refute_includes name.downcase, word, "#{rel}: name '#{name}' contains reserved word '#{word}'."
      end
    end
  end

  def test_description_within_1024_chars
    each_skill do |front, _, rel|
      desc = front["description"].to_s
      refute_empty desc, "#{rel}: description is empty"
      assert_operator desc.length, :<=, MAX_DESCRIPTION_CHARS,
                      "#{rel}: description is #{desc.length} chars, over the #{MAX_DESCRIPTION_CHARS}-char limit."
    end
  end

  def test_description_is_third_person
    each_skill do |front, _, rel|
      desc = front["description"].to_s
      NON_THIRD_PERSON.each do |pattern, reason|
        refute_match pattern, desc, "#{rel}: description #{reason}; write it in third person."
      end
    end
  end

  private

  # GitHub Actions renders `::warning` lines as PR annotations; locally it just
  # prints. Only skills in [WARN, MAX] reach here, so the line is rare noise.
  def warn_near_limit(rel, lines)
    puts "::warning title=SKILL.md approaching length budget::" \
         "#{rel} body is #{lines} lines, nearing the #{MAX_BODY_LINES}-line limit."
  end
end
