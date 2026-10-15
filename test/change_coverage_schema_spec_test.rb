# frozen_string_literal: true

require "minitest/autorun"
require "set"
require_relative "../scripts/change_coverage_schema"

# Keeps the QA coverage data spec honest against ChangeCoverageSchema, as
# change_suite_schema_spec_test.rb does for the suite file. The per-case table
# is checked against CASE_FIELDS and every other field table against FIELDS;
# the two are read apart because a per-case key (`id`, `source`) shares its
# name with a run field.
class ChangeCoverageSchemaSpecTest < Minitest::Test
  SPEC = File.expand_path("../#{ChangeCoverageSchema::SPEC_DOC}", __dir__)
  CASE_SECTION = "## Per-case record"

  def spec_text = @spec_text ||= File.read(SPEC)

  # { section heading => [backticked first cells of its table rows] }, fenced
  # blocks skipped.
  def spec_rows
    @spec_rows ||= begin
      rows = Hash.new { |hash, key| hash[key] = [] }
      section = nil
      in_fence = false
      spec_text.each_line do |line|
        in_fence = !in_fence if line.start_with?("```")
        next if in_fence

        section = line.strip if line.start_with?("## ")
        match = line.match(/^\|\s*`([^`]+)`\s*\|/)
        rows[section] << match[1] if match
      end
      rows
    end
  end

  def run_fields = spec_rows.reject { |section, _| section == CASE_SECTION }.values.flatten
  def case_fields = spec_rows[CASE_SECTION]

  def test_the_spec_doc_exists_where_the_registry_says_it_does
    assert File.exist?(SPEC), "coverage data spec missing at #{ChangeCoverageSchema::SPEC_DOC}"
  end

  def test_spec_has_no_duplicate_fields
    [ run_fields, case_fields ].each do |fields|
      dupes = fields.tally.select { |_, count| count > 1 }.keys
      assert_empty dupes, "coverage data spec lists these fields more than once: #{dupes.join(', ')}"
    end
  end

  def test_spec_and_code_agree_on_the_run_and_meta_fields
    assert_same_set ChangeCoverageSchema::FIELDS, run_fields, "ChangeCoverageSchema::FIELDS"
  end

  def test_spec_and_code_agree_on_the_per_case_fields
    assert_same_set ChangeCoverageSchema::CASE_FIELDS, case_fields, "ChangeCoverageSchema::CASE_FIELDS"
  end

  def test_spec_and_code_agree_on_the_versions
    assert_equal ChangeCoverageSchema::FORMAT_VERSION, spec_text[/^Format version: (\d+)$/, 1].to_i
    assert_equal ChangeCoverageSchema::RUN_SCHEMA, spec_text[/^Run schema: (\d+)$/, 1].to_i
  end

  # The bundle statement a page loads is quoted in the doc; it must name the
  # exact prefix the store writes.
  def test_spec_quotes_the_bundle_prefix_the_store_writes
    assert_includes spec_text, ChangeCoverageSchema::BUNDLE_PREFIX
  end

  # A run file the store writes is a valid run carrying only documented
  # top-level fields.
  def test_a_written_run_file_matches_the_schema
    require "tmpdir"
    require "json"
    require_relative "../scripts/change_coverage_store"
    Dir.mktmpdir do |dir|
      run = { "schema" => ChangeCoverageSchema::RUN_SCHEMA, "id" => "20261013T141500Z-1a2b3c4-run",
              "recorded_at" => "2026-10-13T14:15:00Z", "source" => "change_run", "warnings" => [] }
      written = JSON.parse(File.read(ChangeCoverageStore.write_run(dir, run)))

      assert ChangeCoverageSchema.valid_run?(written)
      tops = ChangeCoverageSchema::FIELDS.map { |field| field.split(/[.\[]/).first }.to_set
      assert_empty written.keys.to_set - tops
    end
  end

  private

  def assert_same_set(coded, documented, name)
    assert_empty (coded.to_set - documented.to_set).to_a.sort, "fields in #{name} but not documented in the spec"
    assert_empty (documented.to_set - coded.to_set).to_a.sort, "fields documented in the spec but not in #{name}"
  end
end
