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

  def test_suggest_keeps_whitespace_and_quoting_in_diff_paths
    path = "infra/my module/main.tf"
    variants = {
      "headers" => "--- a/#{path}\t\n+++ b/#{path}\t\n",
      "deleted headers" => "--- a/#{path}\t\n+++ /dev/null\n",
      "git line only" => "diff --git a/#{path} b/#{path}\nold mode 100644\nnew mode 100755\n",
      "git line, renamed" => "diff --git a/#{path} b/infra/my module/x.txt\nsimilarity index 100%\n",
      "rename records" => "rename from #{path}\nrename to infra/my module/x.txt\n",
      "copy records" => "copy from #{path}\ncopy to infra/x.txt\n",
      "quoted headers" => "--- \"a/infra/t\\303\\251st/main.tf\"\n+++ \"b/infra/tab\\there/main.tf\"\n",
      "quoted git line" => "diff --git \"a/infra/q\\\"x/main.tf\" \"b/infra/q\\\"x/main.tf\"\n",
      "quoted rename" => "rename from \"infra/t\\303\\251st/main.tf\"\nrename to infra/x.txt\n"
    }
    variants.each do |label, diff|
      assert_equal [ "cf:terraform" ], RoastLens.suggest([ [ "change.diff", diff ] ]), label
    end
  end

  def test_diff_paths_ignores_removed_lines_that_look_like_headers
    assert_equal [], RoastLens.diff_paths("--- comment.tf\n+++ added.tf\n")
    assert_equal [ "infra/tést/main.tf" ], RoastLens.diff_paths("+++ \"b/infra/t\\303\\251st/main.tf\"\n")
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

  def test_cli_refuses_unknown_lens_and_routes_lens_with_video
    code, text = run_cli("--brief", @brief, "--text", @tf, "--kind", "infra", "--audience", "ops", "--purpose", "x", "--lens", "nope", "--estimate-only")
    assert_equal 2, code
    assert_match(/--lens nope is not a rubric skill/, text)
    code, text = run_cli("--video", "x.mp4", "--brief", @brief, "--lens", "cf:terraform")
    refute_match(/lenses apply to stills and text only/, text)
    assert_equal 1, code, "a lens is accepted with --video; only the missing MP4 fails"
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

  def test_lens_suggestions_survive_ambiguous_kind
    cfn = File.join(@dir, "notes.txt")
    File.write(cfn, "hello\n")
    code, text = run_cli("infer", "--text", @tf, "--text", cfn)
    assert_equal 3, code
    assert_includes text, "roast lenses suggested: cf:terraform (pass --lens)"
    code, text = run_cli("--brief", @brief, "--text", @tf, "--text", cfn, "--audience", "ops", "--purpose", "x", "--cache", File.join(@dir, ".cache"),
                         "--out-dir", File.join(@dir, "roast"), "--estimate-only")
    assert_equal 3, code
    assert_includes text, "roast lenses suggested: cf:terraform (pass --lens)"
  end
end

# Plan-aware routing (suggest_with_reasons) against the real skills tree, so
# the keyword lists under test are the ones that ship.
class RoastLensPlanRoutingTest < Minitest::Test
  SKILLS_DIR = File.expand_path("../skills", __dir__)

  # The plan's Keyword triggers table, one row per landed lens. Each skill's
  # `lens: keywords:` must equal its row exactly.
  TABLE = <<~TABLE
    | cf:usability | screen, page, form, UI, component |
    | cf:terraform | Terraform, HCL |
    | cf:aws | Lambda, DynamoDB, S3, CloudFront, ECS, Fargate, EKS, RDS, Aurora, SQS, SNS, EventBridge, CloudFormation, CDK |
  TABLE

  def rows
    TABLE.lines.to_h do |line|
      _, lens, words = line.split("|").map(&:strip)
      [ lens, words.split(",").map(&:strip) ]
    end
  end

  # cf:ai-slop is all_files, so it matches plan.md itself on every call;
  # these tests are about what the text adds.
  def routed(text, **opts)
    RoastLens.suggest_with_reasons([ [ "plan.md", text ] ], SKILLS_DIR, plan_text: true, **opts).keys - [ "cf:ai-slop" ]
  end

  def test_every_skill_keyword_list_equals_its_table_row
    assert_equal rows, RoastLens.keywords(SKILLS_DIR)
  end

  def test_each_keyword_selects_its_lens_alone_and_never_glued
    rows.each do |lens, words|
      words.each do |word|
        assert_includes routed("We use #{word} today."), lens, word
        refute_includes routed("We use x#{word} today."), lens, "x#{word}"
        refute_includes routed("We use #{word}x today."), lens, "#{word}x"
      end
    end
  end

  def test_goal_fixtures_route_without_file_paths
    assert_includes routed("A plan for a serverless AWS service on Lambda and DynamoDB."), "cf:aws"
    assert_includes routed("A plan with screens."), "cf:usability"
    assert_equal %w[cf:aws cf:terraform], routed("A plan that rewrites Lambda or Terraform.")
  end

  def test_negatives
    assert_empty routed("Dynamo alone.")
    refute_includes routed("Notes on authoring."), "cf:security"
    assert_includes routed("Two pages."), "cf:usability"
  end

  def test_named_paths_route_and_urls_and_versions_do_not
    result = RoastLens.suggest_with_reasons([ [ "plan.md", "Edit infra/main.tf now." ] ], SKILLS_DIR, plan_text: true)
    assert_equal({ "cf:ai-slop" => [ "path plan.md" ], "cf:terraform" => [ "path infra/main.tf" ] }, result)
    assert_empty RoastLens.named_paths("See https://example.com/main.tf and version 1.2.3.")
    assert_equal [ "infra/main.tf" ], RoastLens.named_paths("Last, edit infra/main.tf.")
    assert_equal [ "infra/main.tf" ], RoastLens.named_paths("Update [infra/main.tf](https://example.com/main.tf).")
    assert_equal %w[app.gemspec invoice.handlebars], RoastLens.named_paths("Update app.gemspec and invoice.handlebars.")
    assert_equal %w[vite.config.ts eslint.config.js], RoastLens.named_paths("Update vite.config.ts and eslint.config.js.")
    assert_includes RoastLens.suggest_with_reasons([ [ "plan.md", "Update vite.config.ts." ] ], SKILLS_DIR, plan_text: true).keys, "cf:typescript"
  end

  def test_bare_basenames_and_dotfiles_route
    result = RoastLens.suggest_with_reasons([ [ "plan.md", "Update Gemfile, Dockerfile and .dockerignore." ] ], SKILLS_DIR, plan_text: true)
    assert_includes result.keys, "cf:docker"
  end

  def test_multi_word_keyword_spans_any_whitespace
    assert RoastLens.keyword_pattern("Cloud Run").match?("on cloud\n  run today")
    refute RoastLens.keyword_pattern("Cloud Run").match?("xCloud Run")
  end

  def test_repo_detect_adds_the_marker_reason
    Dir.mktmpdir do |repo|
      File.write(File.join(repo, "main.tf"), "")
      result = RoastLens.suggest_with_reasons([ [ "plan.md", "Nothing here." ] ], SKILLS_DIR, plan_text: true, repo: repo)
      assert_equal [ "detect *.tf" ], result["cf:terraform"]
    end
  end

  def test_defaults_equal_two_argument_suggest
    texts = [ [ "plan.md", "Edit infra/main.tf for DynamoDB on Lambda." ],
              [ "change.diff", "+++ b/app/x.rb\n" ] ]
    assert_equal RoastLens.suggest(texts, SKILLS_DIR), RoastLens.suggest_with_reasons(texts, SKILLS_DIR).keys
  end

  def test_two_argument_suggest_output_is_pinned
    texts = [ [ "plan.md", "Edit infra/main.tf for DynamoDB on Lambda with screens." ] ]
    assert_equal %w[cf:ai-slop], RoastLens.suggest(texts, SKILLS_DIR)
    diff = [ [ "change.diff", "+++ b/infra/main.tf\n" ] ]
    assert_equal %w[cf:ai-slop cf:terraform], RoastLens.suggest(diff, SKILLS_DIR)
  end

  def test_lens_key_is_not_seen_by_registry_matching
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "x"))
      File.write(File.join(dir, "x", "SKILL.md"),
                 "---\nname: cf:x\ngroup: rubrics\nlens:\n  keywords: [main.tf]\n---\n\nbody\n")
      assert_empty SkillRegistry.load(dir)
      assert_equal({ "cf:x" => [ "main.tf" ] }, RoastLens.keywords(dir))
    end
  end
end
