# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_schema"

# Keeps the golden spec doc honest against the code. The spec
# (skills/change/reference/CHANGE-frontmatter-spec.md) is the human-facing
# authority for authoring CHANGE.md frontmatter; ChangeSchema is the machine
# registry the parser uses. This test fails if they drift: a field in one but
# not the other, or a version mismatch. So a schema change cannot land without
# updating both the code and the doc (including a version bump).
class ChangeSchemaSpecTest < Minitest::Test
  SPEC = File.expand_path("../skills/change/reference/CHANGE-frontmatter-spec.md", __dir__)

  def spec_text = @spec_text ||= File.read(SPEC)

  # The version stated at the top of the spec, e.g. "Schema version: 1.0.0".
  def spec_version
    match = spec_text.match(/^Schema version:\s*(\S+)/)
    refute_nil match, "spec doc is missing a 'Schema version: X.Y.Z' line"
    match[1]
  end

  # Field paths listed in the spec's field tables: the first (backticked) cell of
  # every table row. Table headers, separators, prose bullets, and fenced code
  # blocks have no backticked first cell, so they are skipped. Fenced blocks are
  # excluded outright so an example line can never masquerade as a field row.
  def spec_fields
    fields = []
    in_fence = false
    spec_text.each_line do |line|
      in_fence = !in_fence if line.start_with?("```")
      next if in_fence

      match = line.match(/^\|\s*`([^`]+)`\s*\|/)
      fields << match[1] if match
    end
    fields
  end

  def test_spec_version_matches_the_code
    assert_equal ChangeSchema::VERSION, spec_version,
                 "spec 'Schema version' and ChangeSchema::VERSION disagree; bump both together"
  end

  def test_spec_has_no_duplicate_fields
    dupes = spec_fields.tally.select { |_, count| count > 1 }.keys
    assert_empty dupes, "spec lists these fields more than once: #{dupes.join(', ')}"
  end

  def test_spec_and_code_agree_on_the_field_set
    documented = spec_fields.to_set
    coded = ChangeSchema::FIELDS.to_set

    missing_from_spec = (coded - documented).to_a.sort
    missing_from_code = (documented - coded).to_a.sort

    assert_empty missing_from_spec,
                 "fields in ChangeSchema::FIELDS but not documented in the spec: #{missing_from_spec.join(', ')}"
    assert_empty missing_from_code,
                 "fields documented in the spec but not in ChangeSchema::FIELDS: #{missing_from_code.join(', ')}"
  end
end
