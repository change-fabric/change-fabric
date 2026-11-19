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

  def test_a_legacy_prefixed_approval_matches_the_plain_hex_digest
    hex = "a" * 64
    File.write(File.join(@dir, "abc.json"), %({"sha":"abc","approved":[{"step":"boot.up","digest":"sha256:#{hex}"}]}))
    assert store("abc").approved?("boot.up", hex)
    store("abc").record(steps: [ [ "boot.up", hex ] ], by: "b")
    assert_equal [ [ "boot.up", hex ] ], store("abc").approvals
  end

  def test_empty_without_a_record
    assert_empty store("abc").approvals
  end

  def test_records_and_reads_back_step_digest_pairs
    store("abc").record(steps: [ [ "boot.up", "d1" ] ], by: "someone")
    assert store("abc").approved?("boot.up", "d1")
    refute store("abc").approved?("boot.up", "d2")
    refute store("def").approved?("boot.up", "d1")
  end

  def test_second_record_merges_without_duplicates
    store("abc").record(steps: [ [ "boot.up", "d1" ] ], by: "a")
    store("abc").record(steps: [ [ "boot.up", "d1" ], [ "boot.down", "d2" ] ], by: "b")
    assert_equal [ [ "boot.up", "d1" ], [ "boot.down", "d2" ] ], store("abc").approvals
  end

  def test_write_is_atomic_and_leaves_no_temp_file
    store("abc").record(steps: [ [ "boot.up", "d1" ] ], by: "a")
    assert_equal [ "abc.json" ], Dir.children(@dir)
  end

  def test_a_record_for_another_sha_in_the_file_is_ignored
    File.write(File.join(@dir, "abc.json"), '{"sha":"zzz","approved":[{"step":"boot.up","digest":"d1"}]}')
    assert_empty store("abc").approvals
  end

  def test_corrupt_file_reads_as_empty
    File.write(File.join(@dir, "abc.json"), "{nope")
    assert_empty store("abc").approvals
  end

  def test_a_proofed_record_supersedes_the_entries_it_reapproves
    proof = { "kind" => "totp-terminal", "body" => "{}", "totp_step" => 1, "receipt" => nil }
    store("abc").record(steps: [ [ "boot.up", "d1" ], [ "lane.x", "d3" ] ], by: "a")
    store("abc").record(steps: [ [ "boot.up", "d1" ], [ "boot.down", "d2" ] ], by: "b", proof: proof)
    entries = JSON.parse(File.read(File.join(@dir, "abc.json")))["approved"]
    refute entries[0].key?("proof"), "an entry the new proof does not cover is kept as it was"
    assert_equal [ proof, proof ], entries[1..].map { |entry| entry["proof"] }
    assert_equal [ [ "lane.x", "d3" ], [ "boot.up", "d1" ], [ "boot.down", "d2" ] ], store("abc").approvals
  end

  def test_no_proof_key_without_a_proof
    store("abc").record(steps: [ [ "boot.up", "d1" ] ], by: "a")
    refute JSON.parse(File.read(File.join(@dir, "abc.json")))["approved"][0].key?("proof")
  end
end
