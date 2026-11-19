# frozen_string_literal: true

require_relative "test_helpers"
require "json"
require "stringio"
require_relative "#{SKILL_SCRIPTS}/change_policy"
require_relative "#{SKILL_SCRIPTS}/change_tag_guard"
require_relative "#{SKILL_SCRIPTS}/change_merge_guard"

# ChangePolicy::Source is the single resolver both guards use to decide whose
# CHANGE.md governs an action (#553). Each variant below is one way the
# destination repository can be named. Remote URLs are written as the user
# would (github.com, a GHE host) and mapped onto local fixture repos with
# url.<path>.insteadOf, so nothing touches the network.
class ChangePolicySourceTest < Minitest::Test
  STRICT = "change_policy:\n  promotion:\n    staging: { require_change_pass: true }\n" \
           "    \"tag:staging/v*\": { require_change_pass: true }\n"
  LOOSE = "change_policy:\n  promotion:\n    staging: { require_change_pass: false }\n"

  UP_SSH = "git@github.com:up/proj.git"
  UP_HTTPS = "https://github.com/up/proj.git"
  FORK_SSH = "git@github.com:fork/proj.git"
  GHE_HTTPS = "https://ghe.example.com/up/proj.git"

  def setup
    @dir = Dir.mktmpdir
    @home = Dir.mktmpdir
    @prev_home = Dir.home
    ENV["HOME"] = @home
    @prev_allow = ENV.delete("CF_ALLOW_UNGATED_MERGE")
    @upstream = make_repo("upstream", STRICT)
    @fork = make_repo("fork", LOOSE)
    @ghe = make_repo("ghe", LOOSE)
    @clone = File.join(@dir, "clone")
    git(@dir, "clone", "-q", @fork, @clone)
    git(@clone, "remote", "set-url", "origin", FORK_SSH)
    git(@clone, "remote", "add", "upstream", UP_SSH)
    [ [ @upstream, UP_SSH ], [ @upstream, UP_HTTPS ], [ @fork, FORK_SSH ], [ @ghe, GHE_HTTPS ] ].each do |path, url|
      git(@clone, "config", "--add", "url.#{path}.insteadOf", url)
    end
  end

  def teardown
    ENV["HOME"] = @prev_home
    ENV["CF_ALLOW_UNGATED_MERGE"] = @prev_allow if @prev_allow
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@home)
  end

  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    raise out unless status.success?

    out
  end

  def make_repo(name, policy)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    git(path, "init", "-q", "-b", "main")
    File.write(File.join(path, "CHANGE.md"), "---\n#{policy}---\n")
    git(path, "add", "CHANGE.md")
    git(path, "-c", "user.email=t@t.test", "-c", "user.name=t", "commit", "-q", "-m", "p")
    git(path, "branch", "staging")
    path
  end

  def source(dest) = ChangePolicy::Source.for_destination(@clone, dest)

  # --- URL normalization ------------------------------------------------------

  def test_ssh_https_scp_and_git_suffix_spellings_share_one_identity
    expected = %w[github.com up proj]
    [ "ssh://git@github.com/up/proj.git", "ssh://git@github.com:22/Up/Proj", "https://github.com/up/proj",
      "https://github.com/up/proj.git", "git@github.com:up/proj.git", "github.com:up/proj",
      "https://github.com/up/proj/pull/12" ].each do |url|
      assert_equal expected, ChangePolicy::Source.parse_url(url), url
    end
  end

  def test_names_and_paths_have_no_identity
    assert_nil ChangePolicy::Source.parse_url("origin")
    assert_nil ChangePolicy::Source.parse_url("/tmp/repo")
    assert_nil ChangePolicy::Source.parse_url(nil)
  end

  # --- GHE vs github.com with the same owner/repo -----------------------------

  def test_ghe_pr_never_matches_a_github_com_remote_with_the_same_owner_repo
    refute_equal ChangePolicy::Source.parse_url(GHE_HTTPS), ChangePolicy::Source.parse_url(UP_SSH)
    ghe = ChangePolicy::Source.for_pr_url(@clone, "https://ghe.example.com/up/proj/pull/7")
    assert_equal GHE_HTTPS, ghe.remote
    refute ghe.policy("staging").require_change_pass?("staging")

    dotcom = ChangePolicy::Source.for_pr_url(@clone, "https://github.com/up/proj/pull/7")
    assert_equal "upstream", dotcom.remote
    assert dotcom.policy("staging").require_change_pass?("staging")
  end

  def test_merge_guard_reads_the_ghe_policy_for_a_ghe_pr
    guard = ChangeMergeGuard.new({})
    refute guard.send(:base_policy, @clone, "staging", "https://ghe.example.com/up/proj/pull/7")
                .require_change_pass?("staging")
  end

  # --- fork origin vs upstream ------------------------------------------------

  def test_fork_origin_and_upstream_resolve_to_their_own_policies
    refute source("origin").policy("staging").require_change_pass?("staging")
    assert source("upstream").policy("staging").require_change_pass?("staging")
  end

  def test_fetch_ref_is_namespaced_by_host_owner_and_repo
    assert_equal "refs/cf/policy-base/github.com/up/proj/staging", source("upstream").fetch("staging")
    assert_equal "refs/cf/policy-base/github.com/fork/proj/staging", source("origin").fetch("staging")
  end

  # --- push destinations -------------------------------------------------------

  def test_push_to_a_remote_name
    assert_equal [ "upstream", %w[github.com up proj] ], [ source("upstream").remote, source("upstream").identity ]
  end

  def test_push_to_a_url
    src = source(UP_HTTPS)
    assert_equal %w[github.com up proj], src.identity
    assert src.policy("main").protects_tag?("staging/v1.0.0")
  end

  def test_push_with_no_remote_argument_uses_the_branch_push_remote_else_origin
    assert_equal "origin", source(nil).remote
    git(@clone, "config", "branch.main.pushRemote", "upstream")
    assert_equal "upstream", source(nil).remote
  end

  def test_unknown_destination_resolves_to_nothing
    assert_nil source("nosuchremote")
  end

  # --- tag guard end to end ---------------------------------------------------

  def tag_decision(cmd)
    git(@clone, "tag", "staging/v1.0.0") unless git(@clone, "tag", "-l", "staging/v1.0.0").include?("staging/v1.0.0")
    event = { "tool_name" => "Bash", "tool_input" => { "command" => cmd } }
    guard = ChangeTagGuard.new(event)
    clone = @clone
    guard.define_singleton_method(:repo_root) { clone }
    io = StringIO.new
    guard.emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "permissionDecisionReason")
  end

  def test_tag_push_to_upstream_from_a_fork_is_judged_by_upstream
    assert_match(/no passing a comprehensive cf:change run/, tag_decision("git push upstream staging/v1.0.0"))
    assert_nil tag_decision("git push origin staging/v1.0.0")
  end

  def test_tag_push_with_no_remote_argument_follows_the_push_remote
    assert_nil tag_decision("git push --tags")
    git(@clone, "config", "branch.main.pushRemote", "upstream")
    assert_match(/gated/, tag_decision("git push --tags"))
  end

  def test_tag_push_to_an_unknown_destination_fails_closed_when_governed
    assert_match(/could not be read/, tag_decision("git push nosuchremote staging/v1.0.0"))
  end
end
