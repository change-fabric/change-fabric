# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_selector_suggestions"

# Candidate collection in a real browser: a renamed selector times out, the
# step still fails, and the raw facts come back for the host to score. Pages
# are served by interception, so no server or network is needed.
class ChangeSelectorSuggestionsDockerTest < Minitest::Test
  RENAMED = <<~HTML
    <!doctype html><html><body>
    <button data-testid="add-to-basket">Add to basket</button>
    <input type="password" id="pw" value="hunter2pw"><input type="hidden" id="tok" value="x">
    <iframe srcdoc="<button id='inner'>In frame</button>"></iframe>
    <div id="host"></div>
    <script>document.getElementById("host").attachShadow({ mode: "open" }).innerHTML = '<button data-testid="shadow-go">Go</button>';</script>
    </body></html>
  HTML

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def run_steps(html, steps)
    compiled = ChangeFlowCompiler.new(steps, base_url: "https://fixture.test", timeout_ms: 1500).compile
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        await page.setRequestInterception(true);
        page.on("request", (request) => request.respond({ status: 200, contentType: "text/html", body: #{JSON.generate(html)} }));
        const steps = await cfRunFlow(page, #{JSON.generate(compiled)});
        return { data: { steps }, type: "application/json" };
      };
    JS
    ChangeDocker.with_browserless(network: nil) { |session| session.run_function(code) }["steps"]
  end

  def test_a_renamed_selector_fails_and_lists_the_new_testid_first
    steps = run_steps(RENAMED, [ { "goto" => "/" }, { "click" => "[data-testid=add-to-cart]" } ])
    failed = steps.last

    refute failed["ok"]
    entry = ChangeSelectorSuggestions.build(step_index: failed["index"], selector: failed["selector"], raw: failed["candidates"])
    selectors = entry["candidates"].map { |candidate| candidate["selector"] }

    assert_equal "[data-testid=\"add-to-basket\"]", selectors.first
    assert_operator entry["candidates"].size, :<=, 3
    assert_match(/1 iframe/, entry["note"])
    refute_includes entry.to_s, "hunter2pw"
    refute_includes entry.to_s, "In frame"
  end

  def test_an_empty_page_collects_nothing_and_the_step_still_fails
    steps = run_steps("<!doctype html><html><body></body></html>", [ { "goto" => "/" }, { "click" => "#gone" } ])
    entry = ChangeSelectorSuggestions.build(step_index: 1, selector: "#gone", raw: steps.last["candidates"])

    refute steps.last["ok"]
    assert_empty entry["candidates"]
  end

  def test_a_selector_that_matches_collects_no_candidates
    steps = run_steps(RENAMED, [ { "goto" => "/" }, { "expect_hidden" => "[data-testid=add-to-basket]" } ])

    refute steps.last["ok"]
    assert_nil steps.last["candidates"]
  end
end
