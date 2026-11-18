# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_lane_testcases"

# The evidence dir in a real container: the case module's checkpoints, written
# as downloads into the bind-mounted run dir, land on the host beside the
# start.json and result.json Ruby writes.
class ChangeTestcasesEvidenceDockerTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff, :evidence_dir, :run_id) do
    def log(_message) = nil
    def signoff? = false
  end

  Grader = Struct.new(:unavailable_reason)

  SUITE = <<~YAML
    suite: fixture
    cases:
      - id: page
        acceptance: The fixture page shows its heading.
        steps:
          - eval: "document.body.innerHTML = '<main><h1>Fixture</h1></main>'"
          - expect_visible: h1
          - expect_visible: "#missing"
  YAML

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def test_checkpoints_land_in_the_attempt_dir
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "fixture.cf-testcases.yml"), SUITE)
      root = ChangeTestcasesEvidence.prepare(dir, "run-1")
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ], "timeout_ms" => 2000 }, dir)
      ChangeDocker.with_browserless(network: nil, mounts: { root => ChangeTestcasesEvidence::MOUNT }) do |session|
        ChangeLaneTestcases.new(config, Ctx.new(nil, "https://app.example.org", session, [], false, root, "run-1"),
                                grader: Grader.new("no grader in this test")).run
      end
      attempt = File.join(root, "cases", "fixture", "page", "attempt-1")
      files = Dir.children(attempt).sort
      assert_includes files, "start.json"
      assert_includes files, "result.json"
      assert_includes files, "step-0001-a.json"
      assert_includes files, "step-0003-a.json"
      assert_includes files, "failure.png"
      assert_includes files, "final.png"
      third = JSON.parse(File.read(File.join(attempt, "step-0003-a.json")))
      refute third.dig("record", "ok")
    end
  end
end
