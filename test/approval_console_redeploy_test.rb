# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

# approval_console/infra/redeploy.sh refuses before it touches AWS: the sha must
# be the checked-out HEAD and an ancestor of origin/main, with a clean tree.
# The script runs here inside a throwaway clone; nothing reaches AWS because
# every case stops at a refusal or at the first missing CF_* input.
class ApprovalConsoleRedeployTest < Minitest::Test
  SCRIPT = File.expand_path("../approval_console/infra/redeploy.sh", __dir__)

  def setup
    @dir = File.realpath(Dir.mktmpdir)
    @origin = File.join(@dir, "origin.git")
    @work = File.join(@dir, "work")
    git(@dir, "init", "-q", "--bare", "-b", "main", @origin)
    git(@dir, "clone", "-q", @origin, @work)
    infra = File.join(@work, "approval_console", "infra")
    FileUtils.mkdir_p(infra)
    FileUtils.cp(SCRIPT, File.join(infra, "redeploy.sh"))
    File.write(File.join(infra, "build.sh"), "#!/usr/bin/env bash\nexit 0\n")
    @main = commit("main")
    git(@work, "push", "-q", "origin", "HEAD:main")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args)
    assert status.success?, out
    out.strip
  end

  def commit(name)
    File.write(File.join(@work, name), name)
    git(@work, "add", "-A")
    git(@work, "commit", "-qm", name)
    git(@work, "rev-parse", "HEAD")
  end

  def redeploy(*args, env: {})
    clean = { "CF_AWS_PROFILE" => nil, "CF_ALERT_EMAIL" => nil, "CF_CLAIM_REPOS" => nil }
    out, status = Open3.capture2e(clean.merge(env), "bash", File.join(@work, "approval_console/infra/redeploy.sh"), *args)
    [ status.success?, out ]
  end

  def test_it_takes_exactly_one_full_sha
    ok, out = redeploy
    refute ok
    assert_match(/full 40-character commit sha/, out)
    ok, out = redeploy("abc123")
    refute ok
    assert_match(/full 40-character/, out)
  end

  def test_a_head_that_is_not_the_named_sha_is_refused
    ok, out = redeploy("a" * 40)
    refute ok
    assert_match(/HEAD is #{@main}, not #{'a' * 40}/, out)
  end

  def test_a_sha_that_is_not_an_ancestor_of_origin_main_is_refused
    git(@work, "checkout", "-q", "-b", "side")
    side = commit("side")
    ok, out = redeploy(side)
    refute ok
    assert_match(/not an ancestor of origin\/main/, out)
  end

  def test_a_dirty_tree_is_refused
    File.write(File.join(@work, "scratch"), "x")
    ok, out = redeploy(@main)
    refute ok
    assert_match(/working tree is not clean/, out)
  end

  def test_a_merged_head_with_a_clean_tree_passes_every_check_and_stops_at_the_missing_aws_inputs
    ok, out = redeploy(@main)
    refute ok
    assert_match(/CF_AWS_PROFILE/, out)
    refute_match(/refusing/, out)
  end

  def test_it_never_prompts
    assert_nil File.read(SCRIPT)[/\bread\s+-[a-z]*p|\bread\s+[A-Za-z_]+\s*$|select\s+\w+\s+in/]
  end
end
