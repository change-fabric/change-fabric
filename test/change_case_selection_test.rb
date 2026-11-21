# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_suite"
require_relative "../scripts/change_run"

# The `--case <id>` filter: it narrows the testcases lane to named cases (by
# `suite/id` or a bare id), intersects with --suite and tags, and an unknown id
# is a setup error that lists the known ids.
class ChangeCaseSelectionTest < Minitest::Test
  SUITE = <<~YAML
    suite: checkout
    suite_version: 2
    cases:
      - id: happy-path
        tags: [smoke]
        acceptance: A guest reaches the confirmation page.
        steps:
          - goto: /products/widget
      - id: empty-cart
        tags: [cart]
        acceptance: An empty cart says so.
        steps:
          - goto: /cart
  YAML

  def with_set
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "checkout.cf-testcases.yml"), SUITE)
      yield ChangeSuiteSet.load([ "*.cf-testcases.yml" ], dir)
    end
  end

  def ids(list) = list.map(&:qualified_id)

  def test_a_bare_id_selects_that_case
    with_set { |set| assert_equal [ "checkout/empty-cart" ], ids(set.selected([], case_ids: [ "empty-cart" ])) }
  end

  def test_a_qualified_id_selects_that_case
    with_set { |set| assert_equal [ "checkout/happy-path" ], ids(set.selected([], case_ids: [ "checkout/happy-path" ])) }
  end

  def test_case_ids_repeat
    with_set { |set| assert_equal 2, set.selected([], case_ids: %w[empty-cart happy-path]).size }
  end

  def test_case_narrows_a_suite_selection_and_never_widens_it
    with_set do |set|
      assert_equal [ "checkout/empty-cart" ], ids(set.selected([], selectors: [ "checkout" ], case_ids: [ "empty-cart" ]))
      assert_empty set.selected([], selectors: [ "smoke" ], case_ids: [ "empty-cart" ])
    end
  end

  def test_no_case_ids_leaves_selection_unchanged
    with_set { |set| assert_equal 2, set.selected([]).size }
  end

  def test_unknown_case_ids_are_reported
    with_set { |set| assert_equal [ "nope" ], set.unknown_case_ids([ "empty-cart", "nope" ]) }
  end

  def test_case_flag_parses_and_repeats
    args = ChangeRun.new(%w[all]).send(:parse_args, %w[testcases --case a --case suite/b --case a])
    assert_equal %w[a suite/b], args.cases
  end

  def test_case_flag_is_refused_outside_the_testcases_scope
    runner = ChangeRun.new(%w[all])
    %w[k6 all].each do |scope|
      assert_raises(SystemExit) do
        capture_io { runner.send(:parse_args, [ scope, "--case", "a" ]) }
      end
    end
  end

  def test_an_unknown_case_id_raises_a_setup_error_listing_known_ids
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "checkout.cf-testcases.yml"), SUITE)
      lane = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
      config = Object.new
      config.define_singleton_method(:lane) { |_name| lane }
      runner = ChangeRun.new(%w[all])
      runner.instance_variable_set(:@args, runner.send(:parse_args, %w[testcases --case nope]))
      error = assert_raises(ChangeConfig::ConfigError) { runner.send(:check_case_ids, config, [ "testcases" ]) }
      assert_includes error.message, "checkout/empty-cart"
      assert_includes error.message, "nope"
    end
  end

  def test_a_known_case_id_passes_the_check
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "checkout.cf-testcases.yml"), SUITE)
      lane = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
      config = Object.new
      config.define_singleton_method(:lane) { |_name| lane }
      runner = ChangeRun.new(%w[all])
      runner.instance_variable_set(:@args, runner.send(:parse_args, %w[testcases --case empty-cart]))
      assert_nil runner.send(:check_case_ids, config, [ "testcases" ])
    end
  end
end
