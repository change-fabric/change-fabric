# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../scripts/sweep_trust_store"

class SweepTrustStoreTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @prev = Dir.home
    @repos = []
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @prev
    FileUtils.remove_entry(@home)
    @repos.each { |dir| FileUtils.remove_entry(dir) }
  end

  def store(repo_id = "github.com/acme/web")
    SweepTrustStore.new(repo_id)
  end

  def test_unrecorded_contributor_has_no_level
    assert_nil store.level("octocat")
    refute store.known?("octocat")
  end

  def test_recorded_level_survives_a_new_store_instance
    store.record("octocat", "high")
    assert_equal "high", store("github.com/acme/web").level("octocat")
  end

  # The point of keying on ContributorsTeam's normalized repo_id: two checkouts
  # of one repo, cloned over different protocols, must resolve to one policy.
  def test_ssh_and_https_checkouts_of_one_repo_share_a_record
    ssh = git_repo("git@github.com:acme/web.git")
    https = git_repo("https://github.com/acme/web")
    SweepTrustStore.for_dir(ssh).record("octocat", "low")
    assert_equal "low", SweepTrustStore.for_dir(https).level("octocat")
  end

  # Isolated from any global or system gitconfig: this test only cares that the
  # remote url normalizes, and inheriting the developer's own git setup is how
  # a repo-fixture test picks up unrelated failures.
  ISOLATED_GIT = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL }.freeze

  def git_repo(remote)
    dir = Dir.mktmpdir
    @repos << dir
    system(ISOLATED_GIT, "git", "init", "-q", dir, exception: true)
    system(ISOLATED_GIT, "git", "-C", dir, "config", "--local", "remote.origin.url", remote, exception: true)
    dir
  end

  def test_separate_repos_do_not_share_records
    store("github.com/acme/web").record("octocat", "blocked")
    assert_nil store("github.com/acme/api").level("octocat")
  end

  def test_unknown_returns_only_unrecorded_logins_once
    store.record("octocat", "standard")
    assert_equal [ "hubot" ], store.unknown([ "octocat", "hubot", "hubot" ])
  end

  def test_unrecognized_level_is_rejected
    assert_raises(SweepTrustStore::UnknownLevel) { store.record("octocat", "vibes") }
  end

  def test_forget_makes_a_contributor_unknown_again
    store.record("octocat", "high")
    store.forget("octocat")
    refute store.known?("octocat")
  end

  def test_all_maps_every_login_to_its_level
    store.record("octocat", "high")
    store.record("hubot", "blocked")
    assert_equal({ "octocat" => "high", "hubot" => "blocked" }, store.all)
  end

  def test_repo_id_is_slugged_into_one_path_segment
    refute_includes store.path.sub(File.join(@home, ".claude", "cf", "sweep"), ""), "/acme"
  end

  def test_blank_repo_id_is_not_persistable
    blank = SweepTrustStore.new("")
    blank.record("octocat", "high")
    assert_nil blank.level("octocat")
  end

  def test_corrupt_record_reads_as_empty_rather_than_raising
    store.record("octocat", "high")
    File.write(store.path, "{not json")
    assert_empty store.all
  end

  def test_cli_set_then_unknown_reflects_the_written_policy
    Dir.mktmpdir do |dir|
      run_cli([ "set", "octocat", "high" ], dir)
      assert_equal [ "hubot" ], JSON.parse(run_cli([ "unknown", "octocat", "hubot" ], dir))
    end
  end

  def test_cli_rejects_an_unrecognized_level
    Dir.mktmpdir do |dir|
      assert_equal "unknown_level", JSON.parse(run_cli([ "set", "octocat", "vibes" ], dir))["error"]
    end
  end

  def run_cli(argv, dir)
    out = StringIO.new
    SweepTrustStore::CLI.run(argv, out: out, dir: dir)
    out.string
  end
end
