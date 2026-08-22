# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "tmpdir"
require_relative "../scripts/change_suite_render"
require_relative "../scripts/change_suite"

# Promotion: the flow an exploratory cf:qa run just executed, rendered as a
# committed suite file. The binding property is the round trip. A rendered
# "suite file" the lane would refuse is worse than no output, because it is
# discovered at gate time rather than here.
class ChangeSuiteRenderTest < Minitest::Test
  STEPS = [
    { "goto" => "/products/widget" },
    { "click" => "[data-test=add-to-cart]" },
    { "expect_text" => { "selector" => "[data-test=cart-count]", "equals" => "1" } },
    { "expect_url" => { "contains" => "/confirmation" } }
  ].freeze

  def render(**overrides)
    ChangeSuiteRender.suite_yaml(**{ steps: STEPS, suite: "checkout", id: "guest-checkout",
                                     acceptance: "A guest reaches the confirmation page.",
                                     tags: %w[checkout smoke] }.merge(overrides))
  end

  # The whole point: what is rendered parses back through the lane's own parser,
  # with the case intact.
  def test_the_rendered_yaml_round_trips_through_the_suite_parser
    Dir.mktmpdir do |dir|
      path = File.join(dir, "checkout.cf-testcases.yml")
      File.write(path, render)
      suite = ChangeSuite.load_file(path)

      assert_equal "checkout", suite.name
      assert_equal 1, suite.cases.size
      assert_equal "guest-checkout", suite.cases.first.id
      assert_equal %w[checkout smoke], suite.cases.first.tags
      assert_equal "A guest reaches the confirmation page.", suite.cases.first.acceptance
      assert_equal STEPS, suite.cases.first.steps
    end
  end

  # A flow file names the host it explored; a suite file must not, because the
  # lane supplies the base url per profile and a case pinned to one developer's
  # localhost only ever runs for that developer.
  def test_the_explored_base_url_is_not_promoted
    refute_includes render, "base_url"
  end

  def test_a_retry_budget_is_carried_when_the_flow_had_one
    document = YAML.safe_load(render(retries: 2))

    assert_equal 2, document.fetch("cases").first.fetch("retries")
  end

  def test_no_retries_key_is_emitted_when_the_flow_had_none
    refute_includes render, "retries"
  end

  def test_tags_are_omitted_rather_than_emitted_empty
    refute_includes render(tags: []), "tags"
  end

  # Every field the parser requires is refused here rather than at gate time.
  def test_a_case_with_no_acceptance_is_refused
    error = assert_raises(ChangeSuiteRender::Error) { render(acceptance: "  ") }

    assert_includes error.message, "acceptance"
  end

  def test_a_case_with_no_id_is_refused
    assert_raises(ChangeSuiteRender::Error) { render(id: "") }
  end

  def test_a_suite_with_no_id_is_refused
    assert_raises(ChangeSuiteRender::Error) { render(suite: "") }
  end

  def test_a_flow_with_no_steps_is_refused
    assert_raises(ChangeSuiteRender::Error) { render(steps: []) }
  end

  # A verb the compiler does not know would parse as a step that checks nothing.
  # It fails here, where the author can still see it.
  def test_an_unknown_step_verb_is_refused_at_render_time
    error = assert_raises(ChangeSuiteRender::Error) { render(steps: [ { "got0" => "/cart" } ]) }

    assert_includes error.message, "not a valid suite file"
  end
end
