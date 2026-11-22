# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "open3"
require "rbconfig"
require_relative "../scripts/change_case_draft"

# Case drafts: the skeleton path, and the output never reaching the repo.
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
    ChangeCaseDraft.new(source(diff), **{ routes: routes, out: @out, root: @root }.merge(options)).write
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

  def test_diff_parsing_takes_rename_and_binary_records_and_ignores_header_lookalikes
    diff = <<~DIFF
      diff --git a/old/name.tsx b/app/pricing/page.tsx
      similarity index 100%
      rename from old/name.tsx
      rename to app/pricing/page.tsx
      diff --git a/img/logo.png b/img/logo.png
      Binary files a/img/logo.png and b/img/logo.png differ
      diff --git a/s.rb b/c.rb
      copy from s.rb
      copy to c.rb
      diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
      Binary files differ
      diff --git a/gone.rb b/gone.rb
      deleted file mode 100644
      Binary files a/gone.rb and /dev/null differ
      diff --git a/app/b/x.rb b/app/b/x.rb
      --- a/app/b/x.rb
      +++ b/app/b/x.rb
      @@ -0,0 +2 @@
      +++ not a header
      ++key = 1
    DIFF
    parsed = source(diff)

    assert_equal [ "app/pricing/page.tsx", "img/logo.png", "c.rb", "caf\u00e9.txt", "app/b/x.rb" ], parsed.paths
    assert_equal [ "++ not a header", "+key = 1" ], parsed.added["app/b/x.rb"]
    assert_empty parsed.added["app/pricing/page.tsx"]
  end

  def test_a_quoted_credential_with_spaces_is_redacted_whole
    masked = ChangeCaseDraft.redact(%({"password": "correct horse battery staple"}), env: {})

    refute_match(/horse|staple/, masked)
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

  def test_a_drafts_symlink_into_the_repo_is_refused
    FileUtils.mkdir_p(File.join(@root, "qa"))
    File.symlink(File.join(@root, "qa"), File.join(@out, "drafts"))

    assert_raises(ChangeCaseDraft::Error) { draft }
    assert_empty Dir.children(File.join(@root, "qa"))
  end

  def test_authorization_schemes_are_redacted_with_their_credential
    [ "Authorization: Bearer abc123456789", '{"Authorization": "Bearer abc123456789"}', "Authorization: Basic dXNlcjpwYXNz", "bearer abc123456789" ].each do |line|
      masked = ChangeCaseDraft.redact(line, env: {})

      refute_match(/abc123456789|dXNlcjpwYXNz/, masked)
    end
  end

  def test_a_multi_cookie_header_is_redacted_whole
    [ "Cookie: theme=dark; session_id=abc123456789", '{"cookie": "theme=dark; session_id=abc123456789"}', "Set-Cookie: a=1; sid=abc123456789; Path=/" ].each do |line|
      refute_match(/abc123456789/, ChangeCaseDraft.redact(line, env: {}))
    end
    assert_equal "keep this\n[redacted]", ChangeCaseDraft.redact("keep this\nCookie: a=1; b=2", env: {})
  end

  def test_routes_that_slug_alike_get_distinct_case_ids
    result = ChangeCaseDraft.new(source("+++ b/app/foo/bar/page.tsx\n+x\n"), routes: %w[/foo-bar /foo/bar], out: @out, root: @root).write
    ids = YAML.load_file(result.path)["cases"].map { |item| item["id"] }

    assert_equal 2, ids.uniq.size
  end

  def test_an_empty_diff_is_an_error_and_an_unmatched_diff_writes_nothing
    assert_raises(ChangeCaseDraft::Error) { draft("") }
    assert_nil draft("+++ b/README.md\n+hello\n")
    refute File.exist?(File.join(@out, "drafts"))
  end

  def test_no_routes_writes_nothing
    assert_nil ChangeCaseDraft.new(source, routes: [], out: @out, root: @root).write
  end

  def test_the_root_route_matches_only_a_page_like_file
    assert_nil draft("+++ b/lib/util.rb\n+x\n")
    assert_equal "route-root", YAML.load_file(draft("+++ b/app/page.tsx\n+x\n").path)["cases"].first["id"]
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
    stdout, _err, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--diff", diff, "--out", out_dir, "--change", File.join(@root, "CHANGE.md"))

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
