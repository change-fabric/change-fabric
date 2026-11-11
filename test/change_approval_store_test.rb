# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_approval_store"

# An approval covers one step definition (by digest) at one commit, and
# nothing else.
class ChangeApprovalStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def store(sha) = ChangeApprovalStore.new(sha, root: @dir)

  def test_empty_without_a_record
    assert_empty store("abc").approvals
  end

  def test_records_and_reads_back_step_digest_pairs
    store("abc").record(steps: [ [ "boot.up", "sha256:1" ] ], by: "someone")
    assert store("abc").approved?("boot.up", "sha256:1")
    refute store("abc").approved?("boot.up", "sha256:2")
    refute store("def").approved?("boot.up", "sha256:1")
  end

  def test_second_record_merges_without_duplicates
    store("abc").record(steps: [ [ "boot.up", "sha256:1" ] ], by: "a")
    store("abc").record(steps: [ [ "boot.up", "sha256:1" ], [ "boot.down", "sha256:2" ] ], by: "b")
    assert_equal [ [ "boot.up", "sha256:1" ], [ "boot.down", "sha256:2" ] ], store("abc").approvals
  end

  def test_write_is_atomic_and_leaves_no_temp_file
    store("abc").record(steps: [ [ "boot.up", "sha256:1" ] ], by: "a")
    assert_equal [ "abc.json" ], Dir.children(@dir)
  end

  def test_a_record_for_another_sha_in_the_file_is_ignored
    File.write(File.join(@dir, "abc.json"), '{"sha":"zzz","approved":[{"step":"boot.up","digest":"sha256:1"}]}')
    assert_empty store("abc").approvals
  end

  def test_corrupt_file_reads_as_empty
    File.write(File.join(@dir, "abc.json"), "{nope")
    assert_empty store("abc").approvals
  end
end
