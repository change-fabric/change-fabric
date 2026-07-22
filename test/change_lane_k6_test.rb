# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/change_lane_k6"

# Focuses on the threshold-verdict parsing, the bug the first real dogfood run
# surfaced: k6 --summary-export writes each threshold as a bare boolean that is
# TRUE when breached and FALSE when held, so a held threshold must read as pass.
class ChangeLaneK6Test < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :health_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def lane(config_hash)
    config = ChangeConfig::LaneConfig.new("k6", config_hash, "/repo")
    ChangeLaneK6.new(config, Ctx.new("net", "http://app:3000"))
  end

  # Drives the private threshold parser by writing a real summary.json shaped
  # like k6's export and calling the finding builder through send.
  def findings_for(metrics)
    Dir.mktmpdir do |dir|
      summary = File.join(dir, "summary.json")
      File.write(summary, JSON.generate("metrics" => metrics))
      lane("base_url" => "http://app:3000").send(:threshold_findings, summary)
    end
  end

  def test_held_threshold_bare_false_is_pass
    findings = findings_for("http_req_duration" => { "thresholds" => { "p(95)<500" => false } })
    assert_equal 1, findings.size
    assert_equal "pass", findings.first.status
    assert_equal "threshold met", findings.first.detail
  end

  def test_breached_threshold_bare_true_is_fail
    findings = findings_for("http_req_failed" => { "thresholds" => { "rate<0.01" => true } })
    assert_equal "fail", findings.first.status
    assert_equal "high", findings.first.severity
  end

  def test_object_shaped_threshold_ok_true_is_pass
    findings = findings_for("http_req_duration" => { "thresholds" => { "p(95)<500" => { "ok" => true } } })
    assert_equal "pass", findings.first.status
  end

  def test_object_shaped_threshold_ok_false_is_fail
    findings = findings_for("http_req_duration" => { "thresholds" => { "p(95)<500" => { "ok" => false } } })
    assert_equal "fail", findings.first.status
  end

  def test_metric_without_thresholds_yields_no_findings
    assert_empty findings_for("http_reqs" => { "count" => 3 })
  end

  # The dogfooding fix: a project whose health route is not "/health" (e.g.
  # "/api/health") must not have the default script silently load-test a 404.
  def test_env_defaults_health_path_from_the_boot_health_url
    config = ChangeConfig::LaneConfig.new("k6", {}, "/repo")
    ctx = Ctx.new("net", "http://app:3000", "http://localhost:3000/api/health")
    assert_equal "/api/health", ChangeLaneK6.new(config, ctx).send(:env)["HEALTH_PATH"]
  end

  def test_env_leaves_health_path_unset_without_a_boot_health_url
    config = ChangeConfig::LaneConfig.new("k6", {}, "/repo")
    ctx = Ctx.new("net", "http://app:3000", nil)
    refute ChangeLaneK6.new(config, ctx).send(:env).key?("HEALTH_PATH")
  end

  def test_env_prefers_an_explicitly_configured_health_path
    config = ChangeConfig::LaneConfig.new("k6", { "env" => { "HEALTH_PATH" => "/healthz" } }, "/repo")
    ctx = Ctx.new("net", "http://app:3000", "http://localhost:3000/api/health")
    assert_equal "/healthz", ChangeLaneK6.new(config, ctx).send(:env)["HEALTH_PATH"]
  end
end
