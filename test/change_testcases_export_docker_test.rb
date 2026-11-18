# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_lane_testcases"
require_relative "../scripts/change_testcases_report"
require_relative "../scripts/browserless_pdf"

# The --export acceptance run in real containers, into a non-default --out:
# report.html, report.pdf with every evidence image resolved from the run dir,
# and one MP4 per case, with no paid call anywhere.
class ChangeTestcasesExportDockerTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff, :evidence_dir, :run_id, :exports,
                   :video_budget_mb) do
    def log(_message) = nil
    def signoff? = false
  end

  Grader = Struct.new(:unavailable_reason)

  SUITE = <<~YAML
    suite: fixture
    suite_version: 4
    cases:
      - id: heading
        acceptance: The fixture page shows its heading.
        steps:
          - eval: "document.body.innerHTML = '<main><h1>Fixture</h1><button id=go>Go</button></main>'"
          - expect_visible: h1
          - click: "#go"
          - wait_for_text: Fixture
      - id: missing
        acceptance: The fixture page has no error banner.
        steps:
          - eval: "document.body.innerHTML = '<main><p>Plain</p></main>'"
          - expect_visible: "#banner"
            timeout_ms: 1500
  YAML

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def test_one_run_writes_html_pdf_and_one_mp4_per_case
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "fixture.cf-testcases.yml"), SUITE)
      out = File.join(dir, "custom out")
      root = ChangeTestcasesEvidence.prepare(out, "run-1")
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ], "parallel" => 2 }, dir)
      ChangeDocker.with_browserless(network: nil, mounts: { root => ChangeTestcasesEvidence::MOUNT }) do |session|
        ChangeLaneTestcases.new(config, Ctx.new(nil, "https://app.example.org", session, [], false, root, "run-1", [ "video" ], 64),
                                grader: Grader.new("no grader in this test")).run
      end
      exports = JSON.parse(File.read(File.join(root, "exports.json")))["video"]
      assert_equal %w[ok ok], exports.values_at("fixture/heading", "fixture/missing").map { |entry| entry["status"] }, exports.inspect
      assert File.size(File.join(root, "cases", "fixture", "heading.mp4")).positive?
      assert File.size(File.join(root, "cases", "fixture", "missing.mp4")).positive?

      html = ChangeTestcasesReport.new(run_dir: root, ledger: File.join(dir, "ledger.jsonl")).write[:html]
      assert_includes File.read(html), '<img src="cases/fixture/missing/attempt-1/failure.png"'
      pdf = BrowserlessPdf.render(root)
      assert_equal "%PDF", File.binread(pdf, 4)
    end
  end
end
