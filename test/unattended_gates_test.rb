#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

# Guards the per-skill "## Unattended gates" tables and the citation
# discipline over them. A gate restated in prose instead of cited drifts the
# moment one of them changes; this keeps Steps and Failure modes pointing at
# one table instead of repeating the rule.
class UnattendedGatesTest < Minitest::Test
  SKILLS_DIR = File.expand_path("../skills", __dir__)

  SKILLS = {
    "resolve-threads" => "RT",
    "drive" => "DR",
    "sweep" => "SW",
    "code-review" => "CR",
    "testcases" => "TC",
    "screenshot" => "SS",
    "qa" => "QA"
  }.freeze

  TABLE_HEADER = "| ID | Action | Requires | When unmet |"

  # Only Steps/Workflow/Phase and Failure-modes sections are scanned for
  # citations. Other sections (scope, ref resolution, config shape) use the
  # same English words ("merge-base", "resolvable path") for plain git or
  # file-path meanings that have nothing to do with an unattended gate, and
  # citing those would be noise, not signal.
  SCANNED_HEADING = Regexp.new(%q{^#{1,3}\s*(.*\b(Failure modes|Workflow|Steps|Phase \d+)\b.*)$}, Regexp::IGNORECASE)

  CITE_RE = /\[([A-Z]{2,3}-\d+)\]/
  GATE_WORD_RE = /\b(push|approv|merg|resolv|trust)\w*/i

  def skill_md(name)
    File.read(File.join(SKILLS_DIR, name, "SKILL.md"))
  end

  def test_every_skill_has_exactly_one_gates_table
    SKILLS.each_key do |name|
      text = skill_md(name)
      headings = text.scan(Regexp.new(%q(^#{1,3} Unattended gates\s*$)))
      assert_equal 1, headings.size, "#{name}/SKILL.md must have exactly one '## Unattended gates' heading"
    end
  end

  def test_table_header_and_row_shape
    SKILLS.each do |name, prefix|
      rows = gate_rows(name)
      refute_empty rows, "#{name}/SKILL.md gates table has no rows"
      rows.each do |row|
        cells = row.split("|").map(&:strip).reject(&:empty?)
        assert_equal 4, cells.size, "#{name}/SKILL.md gate row malformed: #{row.inspect}"
        id = cells[0]
        assert_match(/\A#{prefix}-\d+\z/, id, "#{name}/SKILL.md gate id #{id.inspect} must match prefix #{prefix}")
      end
    end
  end

  def test_gate_ids_are_unique_within_each_skill
    SKILLS.each_key do |name|
      ids = gate_rows(name).map { |row| row.split("|").map(&:strip).reject(&:empty?)[0] }
      assert_equal ids.uniq.size, ids.size, "#{name}/SKILL.md has duplicate gate ids: #{ids.inspect}"
    end
  end

  def test_push_approve_merge_resolve_trust_mentions_cite_a_row_id
    SKILLS.each do |name, prefix|
      text = skill_md(name)
      known_ids = gate_rows(name).map { |row| row.split("|").map(&:strip).reject(&:empty?)[0] }
      scanned_text(text).each do |item|
        next unless prose_only(item) =~ GATE_WORD_RE

        cites = item.scan(CITE_RE).flatten
        assert cites.any?, "#{name}/SKILL.md: uncited gate mention: #{item.inspect}"
        cites.each do |id|
          assert known_ids.include?(id),
                 "#{name}/SKILL.md: citation [#{id}] does not name a row in its own gates table"
        end
      end
    end
  end

  def test_citations_use_the_skills_own_prefix
    SKILLS.each do |name, prefix|
      text = skill_md(name)
      scanned_text(text).each do |item|
        item.scan(CITE_RE).flatten.each do |id|
          assert id.start_with?("#{prefix}-"),
                 "#{name}/SKILL.md cites #{id.inspect}, which belongs to a different skill's table"
        end
      end
    end
  end

  private

  # Strips inline `code spans` (CLI subcommand names, literal field names,
  # skill names like `cf:resolve-threads`) before keyword matching: those are
  # identifiers, not the prose stating a gate.
  def prose_only(item)
    item.gsub(/`[^`]*`/, "")
  end

  # Every row between the table header and the next blank line or heading.
  def gate_rows(name)
    text = skill_md(name)
    lines = text.lines
    header_index = lines.index { |l| l.strip == TABLE_HEADER }
    return [] unless header_index

    rows = []
    # header_index + 1 is the "|---|---|---|---|" separator row; skip it.
    (header_index + 2...lines.size).each do |i|
      line = lines[i].strip
      break unless line.start_with?("|")

      rows << line
    end
    rows
  end

  # Splits the scanned sections (Failure modes / Workflow / Steps / Phase N)
  # into paragraph/list-item chunks, skipping fenced code blocks and the
  # gates table itself.
  def scanned_text(text)
    lines = text.lines
    bodies = []
    current = nil
    in_fence = false
    in_table = false
    lines.each do |line|
      if line =~ /^```/
        in_fence = !in_fence
        current << line if current
        next
      end

      if !in_fence && line =~ Regexp.new(%q(^#{1,3}\s))
        bodies << current if current
        current = (line =~ SCANNED_HEADING) ? +"" : nil
        in_table = false
        next
      end

      next if in_fence || current.nil?

      in_table = true if line.strip == TABLE_HEADER
      in_table = false if in_table && line.strip.empty?
      next if in_table

      current << line
    end
    bodies << current if current

    bodies.flat_map { |body| paragraphs(body) }
  end

  # Splits on blank lines and on list-item boundaries ("- " / "1. ").
  def paragraphs(body)
    items = []
    buf = +""
    body.each_line do |line|
      if line.strip.empty?
        items << buf unless buf.strip.empty?
        buf = +""
      elsif line =~ /^\s*(-|\d+[a-z]?\.)\s/ && !buf.strip.empty?
        items << buf
        buf = +"".dup
        buf << line
      else
        buf << line
      end
    end
    items << buf unless buf.strip.empty?
    items
  end
end
