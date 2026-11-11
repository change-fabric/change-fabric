# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/test_shards"

class TestShardsTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)

  def all = TestShards.files(REPO)

  def reports(total)
    TestShards.split(all, total).map { |files| { "files" => files, "runs" => TestShards::MIN_RUNS } }
  end

  def test_every_file_lands_in_exactly_one_shard
    [ 1, 3, 4 ].each do |total|
      shards = TestShards.split(all, total)
      assert_equal total, shards.size
      assert_equal all.sort, shards.flatten.sort
    end
  end

  def test_the_split_is_deterministic
    assert_equal TestShards.split(all, 4), TestShards.split(all.reverse, 4)
  end

  def test_the_heaviest_files_sit_on_separate_shards
    heavy = TestShards::WEIGHTS.sort_by { |_, w| -w }.first(3).map(&:first)
    shards = TestShards.split(all, 4)
    assert_equal 3, heavy.map { |f| shards.index { |s| s.include?(f) } }.uniq.size
  end

  def test_an_unlisted_new_file_lands_in_a_shard
    files = all + [ "test/zz_brand_new_test.rb" ]
    assert_includes TestShards.split(files, 4).flatten, "test/zz_brand_new_test.rb"
  end

  def test_for_spec_reads_one_based_index
    assert_equal TestShards.split(all, 4)[1], TestShards.for_spec("2/4", all)
    assert_raises(ArgumentError) { TestShards.for_spec("0/4", all) }
    assert_raises(ArgumentError) { TestShards.for_spec("5/4", all) }
    assert_raises(ArgumentError) { TestShards.for_spec("two", all) }
  end

  def test_complete_reports_pass
    assert_empty TestShards.problems(reports(4), all)
  end

  def test_a_missing_file_fails
    partial = reports(4)
    dropped = partial[2]["files"].pop
    assert_equal [ "never ran: #{dropped}" ], TestShards.problems(partial, all)
  end

  def test_a_duplicated_file_fails
    doubled = reports(4)
    doubled[0]["files"] += [ doubled[1]["files"].first ]
    assert_match(/more than one shard/, TestShards.problems(doubled, all).join)
  end

  def test_a_file_the_listing_lacks_fails
    extra = reports(4)
    extra[0]["files"] += [ "test/gone_test.rb" ]
    assert_match(/not in test/, TestShards.problems(extra, all).join)
  end

  def test_too_few_runs_fails
    low = reports(4).each { |r| r["runs"] = 1 }
    assert_match(/only 4 runs/, TestShards.problems(low, all).join)
  end

  def test_runs_in_reads_the_minitest_summary
    assert_equal 812, TestShards.runs_in("Run options: --seed 1\n\n812 runs, 9000 assertions, 0 failures, 0 errors, 1 skips\n")
    assert_equal 0, TestShards.runs_in("rake aborted!\n")
  end
end
