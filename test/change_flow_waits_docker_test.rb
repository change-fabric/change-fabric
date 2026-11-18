# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_flow_compiler"

# The event-wait contract in a real browser: a button whose click gets its
# response back at once still satisfies the wait_for_response after it,
# because the listener is armed before the click runs. Requests are answered
# by interception, so the fixture needs no server and no network.
class ChangeFlowWaitsDockerTest < Minitest::Test
  PAGE = <<~HTML
    <!doctype html><html><body>
    <button id="save" onclick="fetch('/api/save', { method: 'POST' }).then(() => { document.getElementById('spinner').remove(); document.body.append('Saved'); })">Save</button>
    <div id="spinner">working</div>
    </body></html>
  HTML

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def run_steps(steps)
    compiled = ChangeFlowCompiler.new(steps, base_url: "https://fixture.test").compile
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        await page.setRequestInterception(true);
        page.on("request", (request) => {
          if (request.url().endsWith("/api/save")) {
            return request.respond({ status: 201, contentType: "application/json", body: "{}" });
          }
          return request.respond({ status: 200, contentType: "text/html", body: #{JSON.generate(PAGE)} });
        });
        const steps = await cfRunFlow(page, #{JSON.generate(compiled)});
        return { data: { steps: steps.map((s) => ({ ok: s.ok, error: s.error, label: s.label })) }, type: "application/json" };
      };
    JS
    ChangeDocker.with_browserless(network: nil) { |session| session.run_function(code) }
  end

  def test_an_immediate_response_still_matches_the_wait_after_its_trigger
    result = run_steps([ { "goto" => "/" }, { "click" => "#save" },
                         { "wait_for_response" => { "url" => "/api/save", "status" => 201 } },
                         { "wait_until_hidden" => "#spinner" }, { "wait_for_text" => "Saved" },
                         { "wait_for_url" => "/" } ])
    assert(result["steps"].all? { |step| step["ok"] }, result["steps"].inspect)
  end
end
