# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_gate_store"

class ChangeGateStoreTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def test_comprehensive_pass_requires_all_scope_and_pass
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    assert store.comprehensive_pass?
  end

  def test_single_lane_pass_does_not_satisfy_gate
    store = ChangeGateStore.new("abc123")
    store.record(scope: "k6", status: "pass", project: "app", lanes: {}, report: "r.md")
    refute store.comprehensive_pass?
  end

  def test_failed_all_run_does_not_satisfy_gate
    store = ChangeGateStore.new("abc123")
    store.record(scope: "all", status: "fail", project: "app", lanes: {}, report: "r.md")
    refute store.comprehensive_pass?
  end

  def test_unknown_sha_is_not_a_pass
    refute ChangeGateStore.new("never-recorded").comprehensive_pass?
  end

  def test_blank_sha_is_not_recordable
    store = ChangeGateStore.new("")
    store.record(scope: "all", status: "pass", project: "app", lanes: {}, report: "r.md")
    assert_nil store.read
  end
end
