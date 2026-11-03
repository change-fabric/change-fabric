# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/roast_lens"
require_relative "../scripts/roast_kind"
require_relative "../scripts/change_schema"

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

  def test_infer_reads_cli_only_kinds
    diff = "diff --git a/app/x.rb b/app/x.rb\n+++ b/app/x.rb\n@@ -1,2 +1,3 @@\n+# Summary\n"
    assert_equal "code", RoastKind.infer(texts: [ [ "change.txt", diff ] ]).kind
    assert_equal "infra", RoastKind.infer(texts: [ [ "main.tf", "variable \"x\" {}\n" ] ]).kind
    arch = RoastKind.infer(texts: [ [ "design.md", "# System\n\n## Architecture\n\nThree services.\n" ] ])
    assert_equal [ "arch", "medium" ], [ arch.kind, arch.confidence ]
  end

  def test_change_schema_still_rejects_cli_only_kinds
    errors = ChangeSchema.roast_review_errors({ "kind" => "code" }, "change_config.design.roast")
    assert_equal 1, errors.size
    assert_match(/kind must be one of/, errors.first)
  end
end
