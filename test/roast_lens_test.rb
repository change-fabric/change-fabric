# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "../scripts/roast"
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
    @brief = File.join(@dir, "brief.txt")
    File.write(@brief, "Review this infra change")
    @tf = File.join(@dir, "main.tf")
    File.write(@tf, "resource \"aws_s3_bucket\" \"b\" {}\n")
    @terms = File.join(@dir, "terms.txt")
    File.write(@terms, "")
    ENV["CF_SENSITIVE_TERMS_FILE"] = @terms
  end

  def teardown
    ENV["CF_SKILLS_DIR"] = @prior
    ENV.delete("CF_SENSITIVE_TERMS_FILE")
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

  def test_suggest_reads_both_sides_of_each_diff_kind
    variants = {
      "deleted" => "--- a/infra/main.tf\n+++ /dev/null\n",
      "added" => "--- /dev/null\n+++ b/infra/main.tf\n",
      "modified" => "--- a/infra/main.tf\n+++ b/infra/main.tf\n",
      "renamed away" => "--- a/infra/main.tf\n+++ b/infra/old.txt\n"
    }
    variants.each do |label, headers|
      diff = "diff --git a/infra/main.tf b/infra/main.tf\n#{headers}@@ -1 +0,0 @@\n"
      assert_equal [ "cf:terraform" ], RoastLens.suggest([ [ "change.diff", diff ] ]), label
    end
  end

  def test_suggest_reads_paths_from_headerless_diff_records
    variants = {
      "pure rename" => "diff --git a/infra/main.tf b/infra/main.txt\nsimilarity index 100%\n" \
                       "rename from infra/main.tf\nrename to infra/main.txt\n",
      "pure copy" => "diff --git a/infra/main.tf b/infra/copy.tf\nsimilarity index 100%\n" \
                     "copy from infra/main.tf\ncopy to infra/copy.tf\n",
      "mode only" => "diff --git a/infra/main.tf b/infra/main.tf\nold mode 100644\nnew mode 100755\n",
      "binary" => "diff --git a/infra/main.tf b/infra/main.tf\nBinary files a/infra/main.tf and b/infra/main.tf differ\n",
      "deleted, no hunks" => "diff --git a/infra/main.tf b/infra/main.tf\ndeleted file mode 100644\nindex e69de29..0000000\n",
      "rename records only" => "rename from infra/main.tf\nrename to infra/main.txt\n"
    }
    variants.each do |label, diff|
      assert_equal [ "cf:terraform" ], RoastLens.suggest([ [ "change.diff", diff ] ]), label
    end
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

  def inputs(lenses: [])
    { brief: "Review this infra change", shots: [], texts: [ @tf ], history: [], round: 1,
      review: { kind: "infra", audience: "operators", purpose: [ "Ship safely" ] }, lenses: lenses }
  end

  def lens(body = "terraform rubric body") = RoastLens::Lens.new("cf:terraform", body)

  def test_lens_body_reaches_the_request_text
    request = Roast.build_request(**inputs(lenses: [ lens ]))
    text = request[:body][:input][1][:content].first[:text]
    assert_includes text, "Lenses:\nLens cf:terraform:\nterraform rubric body"
  end

  def test_request_key_joins_lenses_only_when_present
    base = inputs.except(:lenses)
    plain = Roast.request_key(**base)
    assert_equal plain, Roast.request_key(**base, lenses: [])
    with = Roast.request_key(**base, lenses: [ lens ])
    refute_equal plain, with
    refute_equal with, Roast.request_key(**base, lenses: [ lens("changed body") ])
  end

  def test_round_usd_counts_lens_text
    big = lens("x" * 400_000)
    cache = File.join(@dir, ".cache")
    assert_operator Roast.round_usd(cache, **inputs(lenses: [ big ])), :>, Roast.round_usd(cache, **inputs)
  end

  def test_sensitive_term_in_lens_body_refuses
    File.write(@terms, "secretclient\n")
    args = inputs.slice(:brief, :texts, :review, :history)
    Roast.check_sensitive!(**args)
    assert_raises(Roast::SensitiveError) { Roast.check_sensitive!(**args, lenses: [ lens("mentions secretclient") ]) }
  end

  def run_cli(*argv)
    out = StringIO.new
    [ Roast::Cli.run(argv, out: out), out.string ]
  end

  def test_cli_refuses_unknown_lens_and_lens_with_video
    code, text = run_cli("--brief", @brief, "--text", @tf, "--kind", "infra", "--audience", "ops", "--purpose", "x", "--lens", "nope", "--estimate-only")
    assert_equal 2, code
    assert_match(/--lens nope is not a rubric skill/, text)
    code, text = run_cli("--video", "x.mp4", "--brief", @brief, "--lens", "cf:terraform")
    assert_equal 2, code
    assert_match(/lenses apply to stills and text only/, text)
  end

  def test_cli_estimate_names_lens_and_suggests
    code, text = run_cli("--brief", @brief, "--text", @tf, "--kind", "infra", "--audience", "ops", "--purpose", "x",
                         "--cache", File.join(@dir, ".cache"), "--out-dir", File.join(@dir, "roast"), "--estimate-only")
    assert_equal 0, code
    assert_includes text, "roast lenses suggested: cf:terraform (pass --lens)"
    code, text = run_cli("--brief", @brief, "--text", @tf, "--kind", "infra", "--audience", "ops", "--purpose", "x", "--lens", "terraform",
                         "--cache", File.join(@dir, ".cache"), "--out-dir", File.join(@dir, "roast"), "--estimate-only")
    assert_equal 0, code
    assert_includes text, "1 lens(es)"
    refute_includes text, "suggested"
  end
end
