# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "open3"
require "rbconfig"
require_relative "../scripts/change_case_draft"

# Case drafts: skeleton and model paths, and the output never reaching the repo.
class ChangeCaseDraftTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/change_case_draft.rb", __dir__)

  DIFF = <<~DIFF
    diff --git a/app/pricing/page.tsx b/app/pricing/page.tsx
    --- a/app/pricing/page.tsx
    +++ b/app/pricing/page.tsx
    @@ -1 +1,2 @@
    +export const note = "new plan"
    diff --git a/.env.local b/.env.local
    --- a/.env.local
    +++ b/.env.local
    @@ -1 +1,2 @@
    +API_KEY=hunter2hunter2
    diff --git a/old.txt b/old.txt
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
  DIFF

  def setup
    @root = Dir.mktmpdir("cf-draft-repo")
    @out = Dir.mktmpdir("cf-draft-out")
    File.write(File.join(@root, "CHANGE.md"), <<~MD)
      ---
      change_config:
        lanes:
          browserless:
            routes: [ "/", "/pricing", { path: "/account", auth: true }, "/users/:id", "/blog" ]
          a11y:
            routes: [ "/pricing", "/about" ]
      ---
      body
    MD
  end

  def teardown
    FileUtils.rm_rf([ @root, @out ])
  end

  def source(diff = DIFF) = ChangeCaseDraft.parse_diff(diff, label: "pr-7")
  def routes = ChangeCaseDraft.read_routes(File.join(@root, "CHANGE.md"))

  def draft(diff = DIFF, **options)
    ChangeCaseDraft.new(source(diff), **{ routes: routes, out: @out, root: @root, model: false }.merge(options)).write
  end

  def test_routes_come_from_both_lanes_once_and_skip_non_visitable_paths
    assert_equal %w[/ /pricing /account /blog /about], routes
  end

  def test_diff_parsing_skips_deleted_files_and_never_keeps_sensitive_content
    parsed = source

    assert_equal %w[app/pricing/page.tsx .env.local], parsed.paths
    assert_empty parsed.added[".env.local"]
    assert_equal [ 'export const note = "new plan"' ], parsed.added["app/pricing/page.tsx"]
  end

  def test_skeleton_visits_the_touched_route_and_checks_status
    result = draft
    document = YAML.load_file(result.path)
    item = document["cases"].fetch(0)

    assert_equal "skeleton", result.origin
    assert_equal "draft-pr-7", document["suite"]
    assert_equal ChangeSuiteSchema::SUITE_VERSION, document["suite_version"]
    assert_equal [ { "goto" => "/pricing" }, { "expect_status" => 200 } ], item["steps"]
    assert_equal [ "app/pricing/page.tsx" ], item["covers"]
    assert_equal 1, document["cases"].size, "/blog and /account are untouched"
    assert_match(/\A# DRAFT cases for pr-7/, File.read(result.path))
  end

  def test_the_draft_loads_through_the_suite_parser
    suite = ChangeSuite.load_file(draft.path)

    assert_equal "route-pricing", suite.cases.first.id
  end

  def test_the_draft_path_is_outside_the_repo_and_under_drafts
    result = draft

    assert_equal File.join(@out, "drafts", "pr-7.cf-testcases.yml"), result.path
    refute result.path.start_with?(@root)
  end

  def test_an_output_directory_inside_the_repo_is_refused
    inside = File.join(@root, "qa", "drafts-out")

    error = assert_raises(ChangeCaseDraft::Error) { draft(DIFF, out: inside) }
    assert_match(/inside the repository/, error.message)
    refute File.exist?(inside)
  end

  def test_an_output_symlinked_into_the_repo_is_refused
    holder = Dir.mktmpdir("cf-draft-link")
    link = File.join(holder, "out")
    File.symlink(@root, link)

    assert_raises(ChangeCaseDraft::Error) { draft(DIFF, out: link) }
  ensure
    FileUtils.rm_rf(holder) if holder
  end

  def test_an_empty_diff_is_an_error_and_an_unmatched_diff_writes_nothing
    assert_raises(ChangeCaseDraft::Error) { draft("") }
    assert_nil draft("+++ b/README.md\n+hello\n")
    refute File.exist?(File.join(@out, "drafts"))
  end

  def test_no_routes_and_no_model_writes_nothing
    assert_nil ChangeCaseDraft.new(source, routes: [], out: @out, root: @root, model: false).write
  end

  def test_the_root_route_matches_only_a_page_like_file
    assert_nil draft("+++ b/lib/util.rb\n+x\n")
    assert_equal "route-root", YAML.load_file(draft("+++ b/app/page.tsx\n+x\n").path)["cases"].first["id"]
  end

  def test_model_cases_are_validated_and_unsafe_ones_dropped
    reply = <<~JSON
      ```json
      [ { "id": "Pricing Shows Plan!", "acceptance": "The pricing page lists the new plan.",
          "steps": [ { "goto": "/pricing" }, { "expect_text": "new plan" }, { "expect_status": 200 } ] },
        { "id": "fills", "acceptance": "x", "steps": [ { "fill": "#a" } ] },
        { "id": "external", "acceptance": "x", "steps": [ { "goto": "https://evil.test/" } ] },
        { "id": "secret", "acceptance": "x", "steps": [ { "expect_text": "token=abcdef123456" } ] },
        "junk" ]
      ```
    JSON
    result = draft(DIFF, model: true, runner: ->(_prompt) { reply })
    document = YAML.load_file(result.path)

    assert_equal "model", result.origin
    assert_equal [ "pricing-shows-plan" ], document["cases"].map { |item| item["id"] }
    assert_equal "DRAFT: The pricing page lists the new plan.", document["cases"].first["acceptance"]
    assert_equal 4, result.notes.size
    assert_equal ChangeSuiteSchema::SUITE_VERSION, document["suite_version"]
  end

  def test_model_failure_and_garbage_fall_back_to_the_skeleton
    failing = ->(_prompt) { raise "boom token=abc12345" }
    garbage = ->(_prompt) { "I cannot do that" }

    [ failing, garbage ].each do |runner|
      result = draft(DIFF, model: true, runner: runner)

      assert_equal "skeleton", result.origin
      refute_empty result.notes
      refute_match(/abc12345/, File.read(result.path))
    end
  end

  def test_no_model_skips_the_runner
    result = draft(DIFF, runner: ->(_prompt) { flunk "the model must not run" })

    assert_equal "skeleton", result.origin
  end

  def test_the_prompt_redacts_secrets_and_omits_sensitive_file_content
    seen = nil
    diff = "#{DIFF}+++ b/app/config.rb\n+password = \"s3cret-value\"\n+key = \"envvalue-12345\"\n"
    runner = lambda do |prompt|
      seen = prompt
      "[]"
    end
    draft(diff, model: true, runner: runner, env: { "MY_API_KEY" => "envvalue-12345", "PATH" => "" })

    refute_match(/hunter2|s3cret-value|envvalue-12345/, seen)
    assert_match(/FILE \.env\.local/, seen)
    assert_match(/\[redacted\]/, seen)
  end

  def test_steps_are_capped_and_ids_made_unique
    steps = Array.new(12) { { "goto" => "/pricing" } }
    reply = JSON.generate([ { "id" => "a", "acceptance" => "x", "steps" => steps },
                            { "id" => "b", "acceptance" => "x", "steps" => [ { "goto" => "/" } ] },
                            { "id" => "b", "acceptance" => "x", "steps" => [ { "goto" => "/about" } ] } ])
    cases = YAML.load_file(draft(DIFF, model: true, runner: ->(_prompt) { reply }).path)["cases"]

    assert_equal 8, cases.first["steps"].size
    assert_equal %w[a b b-3], cases.map { |item| item["id"] }
  end

  def test_hostile_text_is_clipped_and_stripped
    clipped = ChangeCaseDraft.clip("a\e[31m#{'x' * 500}")

    refute_match(/\e/, clipped)
    assert_operator clipped.length, :<=, ChangeCaseDraft::CLIP + 3
  end

  def test_cli_writes_a_draft_and_reports_a_bad_invocation
    diff = File.join(@out, "change.diff")
    File.write(diff, DIFF)
    out_dir = Dir.mktmpdir("cf-draft-cli")
    stdout, _err, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--diff", diff, "--out", out_dir, "--change", File.join(@root, "CHANGE.md"), "--no-model")

    assert status.success?, stdout
    assert_match(/1 draft case\(s\) from skeleton/, stdout)
    assert File.file?(File.join(out_dir, "drafts", "diff-change.cf-testcases.yml"))

    _out, err, bad = Open3.capture3(RbConfig.ruby, SCRIPT, "--pr", "1; rm -rf", "--out", out_dir)
    assert_equal 2, bad.exitstatus
    assert_match(/pull request number/, err)

    _out, err, bad = Open3.capture3(RbConfig.ruby, SCRIPT, "--out", out_dir)
    assert_equal 2, bad.exitstatus
    assert_match(/exactly one/, err)
  ensure
    FileUtils.rm_rf(out_dir) if out_dir
  end
end
