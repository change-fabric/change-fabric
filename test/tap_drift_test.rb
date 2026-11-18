# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../scripts/tap_drift"

# The tap must match the newest skills/v* tag: tap-drift.yml alarms when it
# falls behind, and bump-tap-formula.yml pushes straight to the tap.
class TapDriftTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DRIFT = File.join(ROOT, ".github/workflows/tap-drift.yml")
  BUMP = File.join(ROOT, ".github/workflows/bump-tap-formula.yml")
  FORMULA = %(  url "https://github.com/change-fabric/change-fabric/archive/refs/tags/skills/v0.44.0.tar.gz"\n)

  def test_latest_tag_sorts_numerically_and_ignores_other_tracks
    tags = %w[skills/v0.9.0 skills/v0.10.0 spec/v9.0.0 skills/v0.11.0-rc1 image/v1.0.0]
    assert_equal "0.10.0", TapDrift.latest_tag(tags)
  end

  def test_formula_version_reads_the_url_line
    assert_equal "0.44.0", TapDrift.formula_version(FORMULA)
    assert_nil TapDrift.formula_version("class X\nend\n")
  end

  def test_behind_only_when_tag_is_newer
    assert TapDrift.behind?("0.45.0", "0.44.0")
    refute TapDrift.behind?("0.44.0", "0.44.0")
    refute TapDrift.behind?("0.43.0", "0.44.0")
  end

  def test_drift_workflow_is_scheduled_and_uses_only_github_token
    wf = YAML.safe_load_file(DRIFT)
    on = wf["on"] || wf[true]
    assert on.key?("schedule")
    assert on.key?("workflow_dispatch")
    assert_equal({ "contents" => "read", "issues" => "write" }, wf["permissions"])
    refute_includes File.read(DRIFT), "TAP_BUMP_TOKEN"
  end

  def test_bump_pushes_directly_after_install_and_test
    text = File.read(BUMP)
    refute_includes text, "bump-formula-pr"
    assert_includes text, "brew install --build-from-source"
    assert_includes text, "brew test"
    assert_includes text, "git push origin HEAD:main"
  end
end
