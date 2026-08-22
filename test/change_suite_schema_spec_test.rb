# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_suite_schema"

# Keeps the suite-file spec doc honest against the code, exactly as
# change_schema_spec_test.rb does for the CHANGE.md frontmatter spec, and
# deliberately as a second, independent test: the suite file is a different
# document with its own lifecycle, and folding it into the frontmatter drift
# test would make a new step verb look like a CHANGE.md schema change.
class ChangeSuiteSchemaSpecTest < Minitest::Test
  SPEC = File.expand_path("../#{ChangeSuiteSchema::SPEC_DOC}", __dir__)

  def spec_text = @spec_text ||= File.read(SPEC)

  # Field paths are the first (backticked) cell of a table row, the same
  # convention the frontmatter spec's drift test reads. The step-verb table
  # deliberately leads with a plain-text "Kind" column so a verb can never be
  # mistaken for a field path.
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

  def test_the_spec_doc_exists_where_the_registry_says_it_does
    assert File.exist?(SPEC), "suite spec doc missing at #{ChangeSuiteSchema::SPEC_DOC}"
  end

  def test_spec_has_no_duplicate_fields
    dupes = spec_fields.tally.select { |_, count| count > 1 }.keys
    assert_empty dupes, "suite spec lists these fields more than once: #{dupes.join(', ')}"
  end

  def test_spec_and_code_agree_on_the_field_set
    documented = spec_fields.to_set
    coded = ChangeSuiteSchema::FIELDS.to_set

    assert_empty (coded - documented).to_a.sort,
                 "fields in ChangeSuiteSchema::FIELDS but not documented in the suite spec"
    assert_empty (documented - coded).to_a.sort,
                 "fields documented in the suite spec but not in ChangeSuiteSchema::FIELDS"
  end

  # The vocabulary is the compiler's. A doc that named a verb the compiler does
  # not have would promise a step nothing can run.
  def test_every_documented_step_verb_is_one_the_compiler_compiles
    documented = spec_text.scan(/^\| (?:action|assertion|escape hatch) \| (\S+) \|/).flatten
    assert_equal ChangeSuiteSchema::STEP_VERBS.sort, documented.sort
  end
end
