# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_pr_facts"
require_relative "../scripts/merge_confirmation"
require_relative "../scripts/stack_watch"
require_relative "../scripts/change_policy"

# gh 2.105 prints a "hint: ... gh event listen ..." block on stderr. A caller
# that merges stderr into stdout cannot JSON.parse the result. A PATH shim
# prints the hint on stderr and the scripted answer on stdout.
class GhStdoutOnlyTest < Minitest::Test
  HINT = "hint: run gh event listen to follow this pull request"

  def setup
    @dir = Dir.mktmpdir
    @path = ENV.fetch("PATH", "")
    ENV["PATH"] = "#{@dir}:#{@path}"
    File.write(File.join(@dir, "answer"), "{}")
    File.write(File.join(@dir, "gh"), "#!/bin/sh\necho '#{HINT}' >&2\ncat \"#{@dir}/answer\"\n")
    FileUtils.chmod(0o755, File.join(@dir, "gh"))
  end

  def teardown
    ENV["PATH"] = @path
    FileUtils.rm_rf(@dir)
  end

  def answer(text) = File.write(File.join(@dir, "answer"), text)

  def test_pr_facts_gh_ignores_stderr_hint
    answer(JSON.generate("changed_files" => 2))
    assert_equal({ "changed_files" => 2 }, JSON.parse(ChangePrFacts.gh("pr", "view", "--json", "x")))
  end

  def test_merge_confirmation_parses_json_despite_hint
    answer(JSON.generate("state" => "MERGED", "headRefName" => "feat", "number" => 3))
    json, status = MergeConfirmation.gh_pr_view("feat")
    result = MergeConfirmation.evaluate(branch: "feat", kind: "squash_merged", gh_json: json, gh_status: status.success?)
    assert result.confirmed
  end

  def test_stack_watch_gh_json_parses_despite_hint
    answer(JSON.generate("data" => { "ok" => true }))
    watcher = StackWatch.allocate
    assert_equal({ "data" => { "ok" => true } }, watcher.send(:gh_json, "api", "graphql"))
  end

  def test_policy_default_branch_ignores_hint
    answer("main\n")
    assert_equal "main", ChangePolicy.gh_default_branch(@dir, "acme/widgets")
  end
end
