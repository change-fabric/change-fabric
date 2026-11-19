# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../scripts/change_release_store"

# ChangeReleaseStore keeps one verified receipt per exact key, and lookup
# returns it only for that key.
class ChangeReleaseStoreTest < Minitest::Test
  REPO = "repo:github.com/acme/widgets"
  SHA = "b" * 40

  def setup
    @home = Dir.mktmpdir
    @prev = ENV["HOME"]
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
  end

  def store = ChangeReleaseStore.new

  def write(proof: { "kind" => "webauthn+totp" }) = store.record(repo: REPO, tag: "skills/v1.2.3", sha: SHA, proof: proof, policy_sha: "c" * 40, recorded_by: "t")

  def test_records_and_looks_up_the_exact_key
    write
    record = store.lookup(repo: REPO, tag: "skills/v1.2.3", sha: SHA)
    assert_equal [ "webauthn+totp", "c" * 40, "t" ], [ record.dig("proof", "kind"), record["policy_sha"], record["recorded_by"] ]
    assert store.path(repo: REPO, tag: "skills/v1.2.3", sha: SHA).start_with?(File.join(@home, ".claude", "cf", "change", "releases"))
  end

  def test_another_sha_repo_or_tag_finds_nothing
    write
    assert_nil store.lookup(repo: REPO, tag: "skills/v1.2.3", sha: "d" * 40)
    assert_nil store.lookup(repo: "repo:github.com/acme/other", tag: "skills/v1.2.3", sha: SHA)
    assert_nil store.lookup(repo: REPO, tag: "skills/v1.2.4", sha: SHA)
  end

  def test_a_copied_file_does_not_satisfy_another_key
    write
    FileUtils.cp(store.path(repo: REPO, tag: "skills/v1.2.3", sha: SHA), store.path(repo: REPO, tag: "skills/v1.2.3", sha: "d" * 40))
    assert_nil store.lookup(repo: REPO, tag: "skills/v1.2.3", sha: "d" * 40)
  end

  def test_a_malformed_file_finds_nothing
    path = store.path(repo: REPO, tag: "skills/v1.2.3", sha: SHA)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "[not json")
    assert_nil store.lookup(repo: REPO, tag: "skills/v1.2.3", sha: SHA)
  end

  def test_a_new_receipt_replaces_the_old
    write
    write(proof: { "kind" => "webauthn+totp", "n" => 2 })
    assert_equal 2, store.lookup(repo: REPO, tag: "skills/v1.2.3", sha: SHA).dig("proof", "n")
  end
end
