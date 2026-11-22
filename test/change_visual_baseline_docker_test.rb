# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "base64"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_visual_baseline"

# expect_visual in a real browser with the real pixel diff; pages are served
# by interception.
class ChangeVisualBaselineDockerTest < Minitest::Test
  PAGE = <<~HTML
    <!doctype html><html><body style="margin:0">
    <div id="box" style="position:absolute;left:%<left>dpx;top:20px;width:80px;height:60px;background:#06c"></div>
    <div class="clock" style="position:absolute;left:150px;top:20px;width:100px;height:30px;background:#eee">%<time>s</div>
    </body></html>
  HTML

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  # Runs the steps against a page and judges them against `root`'s baselines.
  def run_flow(root, steps, left: 20, time: "10:00")
    html = format(PAGE, left: left, time: time)
    compiled = ChangeFlowCompiler.new(steps, base_url: "https://fixture.test", timeout_ms: 3000).compile
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        await page.setViewport({ width: 300, height: 200 });
        await page.setRequestInterception(true);
        page.on("request", (request) => request.respond({ status: 200, contentType: "text/html", body: #{JSON.generate(html)} }));
        return { data: { steps: await cfRunFlow(page, #{JSON.generate(compiled)}) }, type: "application/json" };
      };
    JS
    ChangeDocker.with_browserless(network: nil) do |session|
      record = { "ok" => true, "steps" => session.run_function(code)["steps"] }
      ChangeVisualBaseline.judge(record, compiled: compiled, root: root, suite: "s", case_id: "c",
                                         runner: ->(diff_code) { session.run_function(diff_code) })
    end
  end

  # What a person's promote command does: the candidate becomes the baseline.
  def accept(root, record)
    path = ChangeVisualBaseline.path_for(root, suite: "s", case_id: "c", name: "hero", viewport: record["visualResults"].first["viewport"])
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Base64.decode64(record["steps"].last["screenshot"]))
  end

  def steps(**spec) = [ { "goto" => "/" }, { "expect_visual" => { "name" => "hero", "max_diff_ratio" => 0 }.merge(spec.transform_keys(&:to_s)) } ]

  def status(record) = record["visualResults"].first["status"]

  def test_a_missing_baseline_blocks_then_the_same_page_matches_and_a_20px_shift_fails
    Dir.mktmpdir do |root|
      first = run_flow(root, steps)

      assert_equal "blocked", status(first)
      refute first["ok"]
      accept(root, first)

      assert_equal "pass", status(run_flow(root, steps))
      assert_equal "fail", status(run_flow(root, steps, left: 40))
    end
  end

  def test_a_masked_timestamp_passes_and_an_unmasked_one_fails
    Dir.mktmpdir do |root|
      accept(root, run_flow(root, steps(mask: [ ".clock" ])))

      assert_equal "pass", status(run_flow(root, steps(mask: [ ".clock" ]), time: "11:11"))
      assert_equal "fail", status(run_flow(root, steps, time: "11:11"))
    end
  end

  def test_a_mask_that_matches_nothing_or_a_missing_element_fails_the_step
    Dir.mktmpdir do |root|
      stale = run_flow(root, steps(mask: [ ".gone" ]))

      assert_match(/matched no element/, stale["steps"].last["error"])
      refute run_flow(root, steps(selector: "#absent"))["steps"].last["ok"]
    end
  end
end
