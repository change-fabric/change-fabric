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

  LEAK_SUITE = <<~YAML
    suite: leak
    suite_version: 8
    cases:
      - id: page
        acceptance: No secret reaches the evidence dir.
        steps:
          - eval: "document.body.innerHTML = '<input id=pw><h1>token hunter2</h1>'"
          - fill: { selector: "#pw", env: LEAK_PW }
          - capture: { var: heading, selector: h1, kind: text }
          - expect_text: { selector: h1, contains: "never there hunter2" }
  YAML

  NUMBER_SUITE = <<~YAML
    suite: number
    suite_version: 8
    cases:
      - id: page
        acceptance: A numeric secret does not break the checkpoint JSON.
        steps:
          - eval: "document.body.innerHTML = '<input id=pw><h1>4242</h1>'"
          - fill: { selector: "#pw", env: LEAK_PW }
          - capture: { var: count, selector: h1, kind: number }
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

  def test_a_numeric_secret_leaves_checkpoints_that_still_parse
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "number.cf-testcases.yml"), NUMBER_SUITE)
      root = ChangeTestcasesEvidence.prepare(dir, "run-1")
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ], "timeout_ms" => 2000 }, dir)
      ENV["LEAK_PW"] = "4242"
      ChangeDocker.with_browserless(network: nil, mounts: { root => ChangeTestcasesEvidence::MOUNT }) do |session|
        ChangeLaneTestcases.new(config, Ctx.new(nil, "https://app.example.org", session, [], false, root, "run-1"),
                                grader: Grader.new("no grader in this test")).run
      end
      attempt = File.join(root, "cases", "number", "page", "attempt-1")
      third = JSON.parse(File.read(File.join(attempt, "step-0003-a.json")))
      assert_equal "[redacted]", third.dig("record", "found")
    ensure
      ENV.delete("LEAK_PW")
    end
  end

  def test_a_secret_never_reaches_a_checkpoint_or_the_result
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "leak.cf-testcases.yml"), LEAK_SUITE)
      root = ChangeTestcasesEvidence.prepare(dir, "run-1")
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ], "timeout_ms" => 2000 }, dir)
      ENV["LEAK_PW"] = "hunter2"
      ChangeDocker.with_browserless(network: nil, mounts: { root => ChangeTestcasesEvidence::MOUNT }) do |session|
        ChangeLaneTestcases.new(config, Ctx.new(nil, "https://app.example.org", session, [], false, root, "run-1"),
                                grader: Grader.new("no grader in this test")).run
      end
      attempt = File.join(root, "cases", "leak", "page", "attempt-1")
      checkpoints = Dir.glob(File.join(attempt, "step-*.json"))
      assert_operator checkpoints.size, :>=, 3
      text = (checkpoints + [ File.join(attempt, "result.json") ]).map { |path| File.read(path) }.join
      refute_includes text, "hunter2"
      assert_includes text, "[redacted]"
    ensure
      ENV.delete("LEAK_PW")
    end
  end
end
