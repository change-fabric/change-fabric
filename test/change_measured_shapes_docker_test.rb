# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_suite"

# The measured-verification shapes in a real browser: each browser-only bug
# class has a v5 case in test/fixtures/suites/measured/ that fails against its
# synthetic bad page and passes against its good page, so every shape is
# discriminating. Pages are served by request interception; no server, no
# network. Needs docker, and skips without it.
class ChangeMeasuredShapesDockerTest < Minitest::Test
  SUITES = File.expand_path("fixtures/suites/measured", __dir__)
  PAGES = File.expand_path("fixtures/measured", __dir__)

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  # Runs the named case against the good and the bad page in one browser.
  def verdicts(name)
    suite = ChangeSuite.load_file(File.join(SUITES, "#{name}.cf-testcases.yml"))
    assert_equal 5, suite.version, "measured shapes are suite v5"
    compiled = ChangeFlowCompiler.new(suite.cases.first.steps, base_url: "https://fixture.test").compile
    pages = %w[good bad].to_h { |kind| [ kind, File.read(File.join(PAGES, "#{name}.#{kind}.html")) ] }
    ChangeDocker.with_browserless(network: nil) do |session|
      pages.to_h { |kind, html| [ kind, run_flow(session, compiled, html)["steps"] ] }
    end
  end

  def run_flow(session, compiled, html)
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        await page.setRequestInterception(true);
        page.on("request", (request) => {
          // /data answers after 1.2 s, so it is in flight when the step runs.
          if (request.url().endsWith("/data")) return setTimeout(() => request.respond({ status: 200, contentType: "application/json", body: "{}" }), 1200);
          return request.respond({ status: 200, contentType: "text/html", body: #{JSON.generate(html)} });
        });
        const steps = await cfRunFlow(page, #{JSON.generate(compiled)});
        return { data: { steps: steps.map((s) => ({ ok: s.ok, error: s.error, label: s.label, durationMs: s.durationMs })) }, type: "application/json" };
      };
    JS
    session.run_function(code)
  end

  def assert_discriminates(name)
    result = verdicts(name)
    assert(result["good"].all? { |step| step["ok"] }, "good page should pass: #{result['good'].inspect}")
    failed = result["bad"].find { |step| !step["ok"] }
    refute_nil failed, "bad page should fail: #{result['bad'].inspect}"
    failed
  end

  def test_class_1_a_scroll_position_lost_on_return_fails
    assert_discriminates("scroll")
  end

  def test_class_2_a_layout_shift_after_load_fails_with_both_values
    failed = assert_discriminates("shift")
    assert_match(/moved from .* to .*tolerance 2px/, failed["error"])
  end

  # The header moves 20 px, then returns before the page settles: first against
  # last would pass; the whole window must not. max_cls is raised so only the
  # pixel excursion can fail it.
  def test_class_2_a_header_that_moves_and_returns_still_fails
    failed = assert_discriminates("excursion")
    assert_match(/moved from .* to .*deviation 2\d(\.\d+)?, tolerance 2px/, failed["error"])
  end

  # Inside a generous pixel tolerance, but the buffered layout-shift entries attribute
  # a shift to the header, and max_cls defaults to 0.
  def test_class_2_a_layout_shift_attributed_to_the_element_fails_max_cls
    failed = assert_discriminates("cls")
    assert_match(/layout shift .* attributed to main h1 exceeds max_cls 0/, failed["error"])
  end

  # The request is outstanding before expect_stable starts. Watching only from
  # that point would call the page idle after 500 ms and miss the shift.
  def test_class_2_a_shift_after_a_request_already_in_flight_fails
    assert_discriminates("inflight")
  end

  def test_class_3_a_sticky_bar_covering_the_first_row_fails
    assert_discriminates("sticky")
  end

  def test_class_4_a_control_clipped_to_zero_width_fails
    assert_discriminates("clipped")
  end

  def test_class_5_a_slow_interaction_fails_its_budget_with_the_measured_time
    failed = assert_discriminates("slow")
    assert_match(/span save\.\.step 3 took \d+ms, budget 1500ms/, failed["error"])
  end

  def test_every_step_records_a_duration
    result = verdicts("slow")
    assert(result["good"].all? { |step| step["durationMs"].is_a?(Integer) })
  end
end
