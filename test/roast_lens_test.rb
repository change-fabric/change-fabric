# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/roast_lens"

class RoastLensTest < Minitest::Test
  SKILLS = {
    "terraform" => "name: terraform\ngroup: rubrics\nauto:\n  extensions: [tf]\n",
    "refactoring" => "name: refactoring\ngroup: rubrics\nauto:\n  all_code: true\n",
    "roast" => "name: roast\n"
  }.freeze

  def setup
    @dir = Dir.mktmpdir("roast-lens")
    SKILLS.each do |name, front|
      FileUtils.mkdir_p(File.join(@dir, name))
      File.write(File.join(@dir, name, "SKILL.md"), "---\n#{front}---\n\n# #{name} rubric body\n")
    end
    @prior = ENV.fetch("CF_SKILLS_DIR", nil)
    ENV["CF_SKILLS_DIR"] = @dir
  end

  def teardown
    ENV["CF_SKILLS_DIR"] = @prior
    FileUtils.rm_rf(@dir)
  end

  def test_rubrics_lists_only_rubric_group_skills
    assert_equal %w[refactoring terraform], RoastLens.rubrics.keys
  end

  def test_resolve_refuses_unknown_and_non_rubric_names
    assert_raises(RoastLens::UnknownLens) { RoastLens.resolve([ "nope" ]) }
    error = assert_raises(RoastLens::UnknownLens) { RoastLens.resolve([ "roast" ]) }
    assert_match(/--lens roast is not a rubric skill/, error.message)
  end

  def test_resolve_accepts_prefixed_and_bare_names
    prefixed = RoastLens.resolve([ "cf:terraform" ])
    assert_equal prefixed, RoastLens.resolve([ "terraform" ])
    assert_equal "cf:terraform", prefixed.first.name
    assert_includes prefixed.first.body, "terraform rubric body"
  end

  def test_suggest_matches_a_tf_path
    assert_equal [ "cf:terraform" ], RoastLens.suggest([ [ "main.tf", "resource \"x\" \"y\" {}" ] ])
  end

  def test_suggest_reads_diff_target_paths
    diff = "diff --git a/infra/main.tf b/infra/main.tf\n+++ b/infra/main.tf\n@@ -1 +1 @@\n" \
           "diff --git a/app/x.rb b/app/x.rb\n+++ b/app/x.rb\n@@ -1 +1 @@\n"
    assert_equal %w[cf:refactoring cf:terraform], RoastLens.suggest([ [ "change.diff", diff ] ])
  end
end
