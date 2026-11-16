# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/change_schedule_store"

class ChangeScheduleStoreTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @store = ChangeScheduleStore.new("nightly-pentest", "staging", repo: "app-1", root: @root)
  end

  def teardown = FileUtils.remove_entry(@root)

  def record(time, result: "pass")
    { "schedule" => "nightly-pentest", "profile" => "staging", "finished_at" => time.utc.iso8601, "result" => result }
  end

  def test_write_names_the_file_by_finish_time_and_points_latest_at_it
    path = @store.write(record(Time.utc(2026, 11, 16, 3, 0, 0)))
    assert_equal File.join(@root, "app-1", "nightly-pentest__staging", "20261116T030000Z.json"), path
    assert_equal "pass", @store.latest["result"]
  end

  def test_latest_follows_the_newest_write
    @store.write(record(Time.utc(2026, 11, 15), result: "pass"))
    @store.write(record(Time.utc(2026, 11, 16), result: "fail"))
    assert_equal "fail", @store.latest["result"]
  end

  def test_latest_is_replaced_by_rename_and_leaves_no_temp_file
    @store.write(record(Time.utc(2026, 11, 16)))
    leftovers = Dir.glob(File.join(@store.dir, "*.tmp"))
    assert_empty leftovers
  end

  def test_same_second_writes_do_not_overwrite
    time = Time.utc(2026, 11, 16)
    @store.write(record(time))
    @store.write(record(time))
    assert_equal 2, @store.records.size
  end

  def test_retention_keeps_the_newest_sixty
    base = Time.utc(2026, 1, 1)
    65.times { |i| @store.write(record(base + (i * 86_400))) }
    names = @store.records.map { |path| File.basename(path) }
    assert_equal 60, names.size
    assert_equal "20260106T000000Z.json", names.first
    assert File.exist?(@store.latest_path)
  end

  def test_latest_is_nil_when_nothing_ran
    assert_nil @store.latest
  end

  def test_default_root_is_under_the_change_store
    assert_equal File.join(Dir.home, ".claude", "cf", "change", "schedules"), ChangeScheduleStore.default_root
  end

  def test_two_repos_with_the_same_names_keep_separate_latest_records
    other = ChangeScheduleStore.new("nightly-pentest", "staging", repo: "app-2", root: @root)
    @store.write(record(Time.utc(2026, 11, 16, 3, 0, 0), result: "pass"))
    other.write(record(Time.utc(2026, 11, 16, 4, 0, 0), result: "fail"))
    assert_equal "pass", @store.latest["result"]
    assert_equal 1, @store.records.size
  end

  def test_repo_key_is_stable_and_differs_by_path
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        assert_equal ChangeScheduleStore.repo_key(a), ChangeScheduleStore.repo_key(a)
        refute_equal ChangeScheduleStore.repo_key(a), ChangeScheduleStore.repo_key(b)
      end
    end
  end
end
