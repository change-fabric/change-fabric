# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/merge_mode_slug"

# The Pi extension normalizes CF_MERGE_MODE and /cf arguments in TypeScript;
# it must agree with MergeModeSlug on every input variant.
class ModeSlugParityTest < Minitest::Test
  HELPER = File.expand_path("../extensions/shared/mode-slug.ts", __dir__)
  VARIANTS = [
    "local-only", "LOCAL-ONLY", "Local only", " local_only ", "Local Only (recommended)",
    "merge-ready", "merge_ready", "Merge ready (default)", "MERGE READY",
    "admin-bypass", "Admin Bypass", "admin bypass (recommended)",
    "yolo", "YOLO", " Yolo ",
    "away", "active", "bogus", "", "---"
  ].freeze

  def ts(known)
    skip "node not available" unless system("node", "-e", "0", out: File::NULL, err: File::NULL)
    script = "import { modeSlug, MERGE_MODES, COMMAND_MODES } from #{HELPER.to_json};" \
             "const v = #{VARIANTS.to_json};" \
             "console.log(JSON.stringify(v.map((x) => modeSlug(x, #{known}) ?? null)));"
    out = IO.popen([ "node", "--experimental-strip-types", "--no-warnings", "--input-type=module", "-e", script ], &:read)
    JSON.parse(out)
  end

  def test_env_default_matches_ruby_normalization
    assert_equal VARIANTS.map { |v| MergeModeSlug.of(v) }, ts("MERGE_MODES")
  end

  def test_command_accepts_merge_modes_plus_away_and_active
    expected = VARIANTS.map { |v| MergeModeSlug.of(v) || (%w[away active].include?(v) ? v : nil) }
    assert_equal expected, ts("COMMAND_MODES")
  end

  def test_env_default_rejects_away
    assert_nil ts("MERGE_MODES")[VARIANTS.index("away")]
  end
end
