# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../scripts/walkthrough_craft"

# The craft gate binds approval to the exact bytes of the final master: each
# craft roast round and each override carries the master's SHA-256.
class WalkthroughCraftTest < Minitest::Test
  P1 = { "priority" => "P1", "timestamp" => "00:03", "where" => "plan", "problem" => "craft: density: six cards at once", "fix" => "split" }.freeze

  def setup
    @root = Dir.mktmpdir
    @dir = File.join(@root, "roast")
    FileUtils.mkdir_p(@dir)
    @master = File.join(@root, "demo-final.mp4")
    File.binwrite(@master, "master one")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def sha = WalkthroughCraft.sha256(@master)

  def round!(n, issues: [], bound_to: sha, response: nil)
    critic = { "score" => 8, "summary" => "s", "issues" => issues, "craft" => { "version" => 1, "master_sha256" => bound_to } }
    File.write(File.join(@dir, "round-#{n}.video.json"), JSON.generate(critic))
    File.write(File.join(@dir, "round-#{n}.video.response.json"), JSON.generate(response)) if response
  end

  def verdict = WalkthroughCraft.verdict(@dir, @master)

  def test_matching_hash_with_no_blockers_approves
    round!(1)
    v = verdict
    assert v[:approved], v[:reason]
    assert_equal 1, v[:round]
  end

  def test_master_changed_after_the_roast_is_stale
    round!(1)
    File.binwrite(@master, "master two")
    v = verdict
    refute v[:approved]
    assert_match(/stale/, v[:reason])
  end

  def test_missing_craft_round_is_refused
    v = verdict
    refute v[:approved]
    assert_match(/no craft roast round/, v[:reason])
    # A video round from before the craft rubric has no binding and does not count.
    File.write(File.join(@dir, "round-1.video.json"), JSON.generate({ "score" => 9, "issues" => [] }))
    refute verdict[:approved]
  end

  def test_missing_master_is_refused
    FileUtils.rm_f(@master)
    refute verdict[:approved]
  end

  def test_open_p1_blocks_without_override
    round!(1, issues: [ P1 ])
    v = verdict
    refute v[:approved]
    assert_match(/1 open craft P0\/P1 in round 1 \(no override recorded\)/, v[:reason])
    assert_includes v[:reason], sha
  end

  def test_override_bound_to_this_master_approves
    round!(1, issues: [ P1 ], response: { "override" => { "by" => "pat", "reason" => "ships as a teaser", "master_sha256" => sha } })
    v = verdict
    assert v[:approved], v[:reason]
    assert_match(/overridden by pat: ships as a teaser/, v[:reason])
  end

  def test_override_bound_to_another_artifact_is_refused
    round!(1, issues: [ P1 ], response: { "override" => { "by" => "pat", "reason" => "x", "master_sha256" => "0" * 64 } })
    v = verdict
    refute v[:approved]
    assert_match(/bound to another artifact/, v[:reason])
  end

  def test_override_without_a_reason_is_refused
    round!(1, issues: [ P1 ], response: { "override" => { "by" => "pat", "master_sha256" => sha } })
    refute verdict[:approved]
  end

  def test_newest_round_for_this_master_decides
    round!(1, issues: [ P1 ])
    round!(2)
    assert verdict[:approved]
    round!(3, issues: [ P1 ], bound_to: "f" * 64)
    assert verdict[:approved], "a later round of another artifact does not reopen this master"
  end

  def test_cli_exit_codes
    script = File.expand_path("../scripts/walkthrough_craft.rb", __dir__)
    out, status = Open3.capture2e("ruby", script, @root)
    assert_equal 1, status.exitstatus
    assert_match(/not approved/, out)
    round!(1)
    out, status = Open3.capture2e("ruby", script, @root)
    assert status.success?, out
  end
end
