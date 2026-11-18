# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "git_fixture"
require_relative "../scripts/change_trust"
require_relative "../scripts/change_config"

# A command entry's trust digest covers the repo files its `run` invokes and
# its `trust_paths:` globs, so editing a script the lane calls needs the same
# approval as editing the entry.
class ChangeTrustFilesTest < Minitest::Test
  STEP = "command:ci"

  def setup
    @home = Dir.mktmpdir
    @prev_home = ENV["HOME"]
    ENV["HOME"] = @home
    @repo = Dir.mktmpdir
    GitFixture.git_init(@repo, "-b", "main")
  end

  def teardown
    ENV["HOME"] = @prev_home
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
  end

  def change_md(trust_paths: nil)
    extra = trust_paths ? ", trust_paths: #{trust_paths.inspect}" : ""
    <<~MD
      ---
      change_config:
        project: demo
        lanes:
          command:
            commands:
              - { name: ci, run: "bash scripts/ci.sh ci HEAD", timeout_seconds: 60#{extra} }
      ---
    MD
  end

  def commit(files)
    files.each do |rel, body|
      path = File.join(@repo, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    GitFixture.git(@repo, "add", "-A")
    GitFixture.git(@repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c")
    GitFixture.git(@repo, "rev-parse", "HEAD").strip
  end

  def base!(files)
    sha = commit(files)
    GitFixture.git(@repo, "update-ref", "refs/remotes/origin/main", sha)
    sha
  end

  def verdict_for(sha)
    defs = ChangeTrust.snapshot_definitions(@repo, sha)
    ChangeTrust.evaluate(root: @repo, head_sha: sha, head_definitions: defs, fetch: false)
  end

  def test_edited_script_with_unchanged_entry_needs_approval
    base!("CHANGE.md" => change_md, "scripts/ci.sh" => "echo ok\n")
    head = commit("scripts/ci.sh" => "exit 0\n")
    verdict = verdict_for(head)
    assert_equal [ STEP ], verdict.untrusted
    assert_match(%r{covered files changed: scripts/ci\.sh}, verdict.refusal(STEP))
  end

  def test_unchanged_script_passes
    base!("CHANGE.md" => change_md, "scripts/ci.sh" => "echo ok\n")
    head = commit("README" => "unrelated\n")
    assert verdict_for(head).trusted?(STEP)
  end

  def test_working_tree_definitions_match_the_snapshot
    sha = base!("CHANGE.md" => change_md, "scripts/ci.sh" => "echo ok\n")
    tree = ChangeTrust.step_definitions(ChangeConfig.load(File.join(@repo, "CHANGE.md")))
    assert_equal ChangeTrust.snapshot_definitions(@repo, sha)[STEP], tree[STEP]
    assert_equal [ "scripts/ci.sh" ], tree[STEP]["files"].keys
  end

  def test_trust_paths_glob_catches_a_sourced_file
    md = change_md(trust_paths: [ "scripts/ci/**" ])
    base!("CHANGE.md" => md, "scripts/ci.sh" => "source scripts/ci/lib.sh\n", "scripts/ci/lib.sh" => "a=1\n")
    head = commit("scripts/ci/lib.sh" => "a=2\n")
    verdict = verdict_for(head)
    assert_equal [ STEP ], verdict.untrusted
    assert_match(%r{scripts/ci/lib\.sh}, verdict.refusal(STEP))
  end

  def test_script_followed_by_a_shell_operator_is_covered
    entry = { "name" => "ci", "run" => "bash scripts/ci.sh; sh -c 'bash scripts/b.sh'&&true" }
    commit("scripts/ci.sh" => "a\n", "scripts/b.sh" => "b\n")
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal %w[scripts/b.sh scripts/ci.sh], files.keys
  end

  def test_symlink_covers_its_target_the_same_in_tree_and_snapshot
    commit("scripts/real.sh" => "echo hi\n")
    File.symlink("real.sh", File.join(@repo, "scripts/ci.sh"))
    sha = commit({})
    entry = { "name" => "ci", "run" => "bash scripts/ci.sh" }
    tree = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    snap = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.at_ref(@repo, sha, @repo))
    assert_equal %w[scripts/ci.sh scripts/real.sh], tree["files"].keys
    assert_equal tree, snap
  end

  def test_quoted_filename_with_a_space_is_covered
    commit("scripts/ci check.sh" => "a\n")
    entry = { "name" => "ci", "run" => 'bash "scripts/ci check.sh"' }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal [ "scripts/ci check.sh" ], files.keys
  end

  def test_symlinked_directory_prefix_is_followed
    commit("scripts/ci.sh" => "a\n")
    File.symlink("scripts", File.join(@repo, "alias"))
    sha = commit({})
    entry = { "name" => "ci", "run" => "bash alias/ci.sh" }
    tree = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    assert_equal %w[alias scripts/ci.sh], tree["files"].keys
    assert_equal tree, ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.at_ref(@repo, sha, @repo))
  end

  def test_link_to_a_path_through_a_linked_directory_is_followed
    commit("scripts/ci.sh" => "a\n")
    File.symlink("scripts", File.join(@repo, "alias"))
    File.symlink("alias/ci.sh", File.join(@repo, "ci.sh"))
    entry = { "name" => "ci", "run" => "bash ci.sh" }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal %w[alias ci.sh scripts/ci.sh], files.keys
  end

  def test_dotdot_after_a_linked_directory_fails_closed
    commit("other/ci.sh" => "a\n", "other/deep/x" => "x\n", "scripts/ci.sh" => "b\n")
    File.symlink("../other/deep", File.join(@repo, "scripts/link"))
    entry = { "name" => "ci", "run" => "bash scripts/link/../ci.sh" }
    coverage = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    assert_match(/cannot be followed/, coverage["error"])
  end

  def test_shell_glob_in_run_is_expanded
    commit("scripts/ci.sh" => "a\n")
    entry = { "name" => "ci", "run" => "bash scripts/c*.sh" }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal [ "scripts/ci.sh" ], files.keys
  end

  def test_trust_paths_glob_through_a_linked_directory
    commit("scripts/helper.sh" => "a\n")
    File.symlink("scripts", File.join(@repo, "alias"))
    entry = { "name" => "ci", "run" => "true", "trust_paths" => [ "alias/**" ] }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal %w[alias scripts/helper.sh], files.keys
  end

  def test_link_target_with_dotdot_after_a_linked_directory_fails_closed
    commit("other/ci.sh" => "a\n", "other/deep/x" => "x\n", "scripts/ci.sh" => "b\n")
    File.symlink("../other/deep", File.join(@repo, "scripts/link"))
    File.symlink("scripts/link/../ci.sh", File.join(@repo, "ci.sh"))
    entry = { "name" => "ci", "run" => "bash ci.sh" }
    coverage = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    assert_match(/cannot be followed/, coverage["error"])
  end

  def test_wildcard_prefix_follows_a_linked_directory
    commit("other/ci.sh" => "a\n", "scripts/x" => "x\n")
    File.symlink("../other", File.join(@repo, "scripts/alias"))
    entry = { "name" => "ci", "run" => "bash scripts/*/ci.sh" }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal %w[other/ci.sh scripts/alias], files.keys
  end

  def test_successive_cds_compose
    commit("scripts/nested/ci.sh" => "a\n")
    entry = { "name" => "ci", "run" => "cd scripts && cd nested && bash ci.sh" }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal [ "scripts/nested/ci.sh" ], files.keys
  end

  def test_nested_shell_quoting_is_parsed
    commit("scripts/ci check.sh" => "a\n")
    entry = { "name" => "ci", "run" => %q(sh -c 'bash "scripts/ci check.sh"') }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal [ "scripts/ci check.sh" ], files.keys
  end

  def test_cd_in_the_command_is_followed
    commit("scripts/ci.sh" => "a\n")
    entry = { "name" => "ci", "run" => "cd scripts && bash ci.sh" }
    files = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["files"]
    assert_equal [ "scripts/ci.sh" ], files.keys
    entry["run"] = "cd $DIR && bash ci.sh"
    assert_match(/cannot be followed/, ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))["error"])
  end

  def test_symlinked_directory_outside_the_repo_is_refused
    File.symlink("/tmp", File.join(@repo, "out"))
    entry = { "name" => "ci", "run" => "bash out/ci.sh" }
    coverage = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    assert_match(/points outside the repo/, coverage["error"])
  end

  def test_symlink_outside_the_repo_is_refused
    File.symlink("/etc/hosts", File.join(@repo, "ci.sh"))
    entry = { "name" => "ci", "run" => "bash ci.sh" }
    coverage = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    assert_match(/points outside the repo/, coverage["error"])
  end

  def test_file_missing_on_one_side_is_a_change
    base!("CHANGE.md" => change_md)
    head = commit("scripts/ci.sh" => "echo new\n")
    assert_equal [ STEP ], verdict_for(head).untrusted
  end

  def test_path_escaping_the_root_is_refused
    entry = { "name" => "ci", "run" => "true", "trust_paths" => [ "../outside/**" ] }
    coverage = ChangeTrustFiles.cover(entry, ChangeTrustFiles::Source.working_tree(@repo))
    assert_match(/escapes the repo root/, coverage["error"])
    errors = ChangeCommandConfig.errors({ "commands" => [ entry.merge("timeout_seconds" => 5) ] })
    assert(errors.any? { |error| error.include?("trust_paths") })
    assert_nil ChangeTrustFiles.normalize("../x.sh")
    assert_nil ChangeTrustFiles.normalize("scripts/../../x.sh")
  end

  def test_over_the_cap_fails_closed_even_when_unchanged
    files = (0..ChangeTrustFiles::MAX_FILES).to_h { |index| [ "scripts/ci/f#{index}.sh", "x\n" ] }
    head = base!(files.merge("CHANGE.md" => change_md(trust_paths: [ "scripts/ci/**" ])))
    verdict = verdict_for(head)
    assert_equal [ STEP ], verdict.untrusted
    assert_match(/cannot be verified: covers \d+ files, over the 200-file cap/, verdict.refusal(STEP))
    assert verdict.head_digests[STEP].start_with?(ChangeTrust::UNVERIFIED)
  end

  def test_unverified_step_is_trusted_once_approved
    files = (0..ChangeTrustFiles::MAX_FILES).to_h { |index| [ "scripts/ci/f#{index}.sh", "x\n" ] }
    head = base!(files.merge("CHANGE.md" => change_md(trust_paths: [ "scripts/ci/**" ])))
    digest = verdict_for(head).head_digests[STEP]
    ChangeApprovalStore.new(head).record(steps: [ [ STEP, digest ] ], by: "t")
    assert_equal :approved, verdict_for(head).sources[STEP]
  end
end
