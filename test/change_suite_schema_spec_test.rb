# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_suite_schema"
require_relative "../scripts/change_suite"

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
    documented = spec_text.scan(/^\| (?:action|state wait|event wait|assertion|escape hatch) \| (\S+) \|/).flatten
    assert_equal ChangeSuiteSchema::STEP_VERBS.sort, documented.sort
  end

  # --- suite_version ------------------------------------------------------------

  def test_the_spec_doc_names_the_installed_suite_version
    assert_match(/^Suite version: #{ChangeSuiteSchema::SUITE_VERSION}$/, spec_text)
  end

  # Every version-gated field's "Since" cell agrees with FIELD_VERSIONS, so the
  # doc cannot tell an author a key is older than the loader accepts.
  def test_the_spec_doc_records_the_version_each_field_was_added
    spec_text.each_line do |line|
      match = line.match(/^\|\s*`([^`]+)`\s*\|.*\|\s*(\d+)\s*\|\s*$/)
      next unless match

      assert_equal ChangeSuiteSchema.field_version(match[1]), match[2].to_i, "Since cell for #{match[1]}"
    end
  end

  COMPAT = File.expand_path("fixtures/suites/compat", __dir__)

  def compat(name) = File.join(COMPAT, "#{name}.cf-testcases.yml")

  def test_a_v1_file_with_no_suite_version_still_loads
    suite = ChangeSuite.load_file(compat("v1"))
    assert_equal 1, suite.version
    assert_equal [ "home" ], suite.cases.map(&:id)
  end

  def test_a_v2_file_loads_its_v2_fields
    item = ChangeSuite.load_file(compat("v2")).cases.first
    assert_equal 60_000, item.timeout_ms
    assert item.safe_rerun
    assert_equal 1, item.retries
  end

  def test_a_v3_file_loads_its_persona_fields
    item = ChangeSuite.load_file(compat("v3")).cases.first
    assert_equal "admin", item.persona
    assert item.safe_retry
  end

  def test_a_v4_file_loads_its_waits
    steps = ChangeSuite.load_file(compat("v4")).cases.first.steps
    assert_equal 7, steps.size
  end

  def test_a_v5_file_loads_its_measured_steps
    steps = ChangeSuite.load_file(compat("v5")).cases.first.steps
    assert_equal 8, steps.size
  end

  def test_a_v8_file_loads_relations_lists_and_preconditions
    item = ChangeSuite.load_file(compat("v8")).cases.first
    assert_equal 8, ChangeSuite.load_file(compat("v8")).version
    assert_equal 2, item.preconditions.size
    assert_equal %w[expect_relation], item.steps.flat_map(&:keys).grep(/expect_relation/).uniq
    assert item.blocks_on_login?
  end

  def test_a_v5_file_may_not_use_the_v8_verb_kind_or_preconditions
    [
      { "expect_relation" => { "relation" => "le", "reads" => { "a" => 1, "b" => 2 } } },
      { "capture" => { "selector" => "li", "as" => "items", "kind" => "list" } }
    ].each do |step|
      error = assert_raises(ChangeSuite::Error, step.keys.first) { ChangeSuite.steps([ { "goto" => "/" }, step ], "s", "c", "p", 5) }
      assert_includes error.message, "added in suite_version 8"
    end
    raw = { "id" => "c", "acceptance" => "a", "preconditions" => [ { "goto" => "/" } ], "steps" => [ { "goto" => "/" } ] }
    error = assert_raises(ChangeSuite::Error) { ChangeSuite.parse_case(raw, "s", "p", 0, 5) }
    assert_includes error.message, "`preconditions`, added in suite_version 8"
    assert_equal 1, ChangeSuite.parse_case(raw, "s", "p", 0, 8).preconditions.size
  end

  def test_preconditions_must_be_a_non_empty_list_of_valid_steps
    base = { "id" => "c", "acceptance" => "a", "steps" => [ { "goto" => "/" } ] }
    [ [], "goto", [ { "nope" => 1 } ] ].each do |bad|
      assert_raises(ChangeSuite::Error, bad.inspect) { ChangeSuite.parse_case(base.merge("preconditions" => bad), "s", "p", 0, 8) }
    end
    assert_empty ChangeSuite.parse_case(base, "s", "p", 0, 8).preconditions
  end

  def test_an_older_suite_keeps_failing_the_gate_on_a_lost_login
    refute ChangeSuite.load_file(compat("v5")).cases.first.blocks_on_login?
    refute ChangeSuite.load_file(compat("v4")).cases.first.blocks_on_login?
  end

  def test_a_v4_file_may_not_use_the_v5_options_or_kinds
    {
      "budget_ms" => { "wait_for_text" => "x", "budget_ms" => 10 },
      "label" => { "click" => "#a", "label" => "go" },
      "rect.y" => { "capture" => { "selector" => "h1", "as" => "y", "kind" => "rect.y" } },
      "tolerance" => { "expect_equal" => { "var" => "y", "selector" => "h1", "tolerance" => 1 } }
    }.each do |key, step|
      error = assert_raises(ChangeSuite::Error, key) { ChangeSuite.steps([ { "goto" => "/" }, step ], "s", "c", "p", 4) }
      assert_includes error.message, "added in suite_version 5"
      assert_includes error.message, "`#{key}`"
    end
    ChangeSuite.steps([ { "goto" => "/" }, { "wait_for_text" => "x", "budget_ms" => 10 } ], "s", "c", "p", 5)
  end

  def test_the_seventeen_case_v4_fixture_loads_under_the_current_loader
    suite = ChangeSuite.load_file(compat("v4-seventeen"))
    assert_equal 4, suite.version
    assert_equal 17, suite.cases.size
  end

  def test_a_file_newer_than_the_install_names_the_update
    assert_equal ChangeSuiteSchema::SUITE_VERSION + 1, YAML.safe_load_file(compat("too-new"))["suite_version"],
                 "raise the too-new fixture with SUITE_VERSION"
    error = assert_raises(ChangeSuite::Error) { ChangeSuite.load_file(compat("too-new")) }
    assert_includes error.message, "needs a newer cf toolkit; pull and run ruby install.rb"
  end

  def test_a_key_newer_than_the_declared_version_names_the_version_that_adds_it
    error = assert_raises(ChangeSuite::Error) { ChangeSuite.load_file(compat("newer-key")) }
    assert_includes error.message, "added in suite_version #{ChangeSuiteSchema::SUITE_VERSION}"
  end
end
