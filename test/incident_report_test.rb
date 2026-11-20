# frozen_string_literal: true

require "minitest/autorun"
require "zlib"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "base64"
require_relative "git_fixture"
require_relative "../scripts/incident_report"
require_relative "key_project_helpers"

# Fakes only: no docker, no network, no paid call. roast.rb, typst and the OCR
# container are stubbed; the browser module runs under node against a fake page.
class IncidentReportTest < Minitest::Test
  include KeyProjectHelpers

  T0 = "2026-03-02T10:00:00Z"
  T1 = "2026-03-02T10:05:00Z"
  T2 = "2026-03-02T11:00:00Z"
  PNG = begin
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR", [ 1, 1, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate("\x00\xff\xff\xff".b)) + chunk.call("IEND", "")
  end
  NODE = Open3.capture2e("node", "--version").then { |_, s| s.success? } rescue false

  # Stands in for roast.rb and typst. Roast writes a round file with
  # the configured score and P0 count; builds write placeholder files.
  class FakeShell
    attr_reader :calls
    attr_accessor :score, :p0, :no_typst

    def initialize
      @calls = []
      @score = 9
      @p0 = 0
    end

    def run(argv, env: {}, chdir: nil)
      @calls << argv
      return settings if argv.include?("settings")
      return roast(argv) if argv.any? { |a| a.end_with?("roast.rb") }
      return [ "typst 0.13\n", !@no_typst ] if argv == %w[typst --version]
      return (argv.include?("--format") ? png(argv) : pdf(argv)) if argv.first(2) == %w[typst compile]

      [ "unexpected #{argv.inspect}", false ]
    end

    def roast_calls = @calls.select { |c| c.any? { |a| a.end_with?("roast.rb") } && !c.include?("settings") }

    private

    def settings = [ "roast settings: auto true, target 8, rounds 5, max_usd 0.50, model x\n", true ]

    def roast(argv)
      return [ "roast refused: no audience", false ] unless argv.include?("--audience")
      return [ "roast refused: no purpose", false ] unless argv.include?("--purpose")

      dir = argv[argv.index("--out-dir") + 1]
      FileUtils.mkdir_p(dir)
      issues = Array.new(@p0) { { "priority" => "P0", "where" => "x", "problem" => "p", "fix" => "f" } }
      File.write(File.join(dir, "round-1.json"), JSON.generate("score" => @score, "issues" => issues))
      [ "roast ok\n", true ]
    end

    def pdf(argv)
      File.binwrite(argv.last, "%PDF-fake #{File.read(argv[2]).bytesize}")
      [ "", true ]
    end

    def png(argv)
      template = argv.last
      2.times { |i| File.binwrite(template.sub("{0p}", format("%d", i + 1)), PNG + i.to_s) }
      [ "", true ]
    end
  end

  class FakeBrowser
    attr_reader :code

    def initialize(result) = @result = result

    def run_function(code, launch_args: [])
      @code = code
      @result
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @root = File.join(@tmp, "incidents")
    @client = File.join(@tmp, "notes", "<client>", "<date>")
    @terms = File.join(@tmp, "terms.txt")
    File.write(@terms, "zorblax\n")
    @env = { "CF_SENSITIVE_TERMS_FILE" => @terms }
    @prev = ENV.to_h.slice("CF_SENSITIVE_TERMS_FILE", "CF_INCIDENTS_DIR", "CF_KNOWN_REPO_ROOTS", "CF_INCIDENT_CLIENT_DIR")
    ENV["CF_SENSITIVE_TERMS_FILE"] = @terms
    ENV["CF_INCIDENTS_DIR"] = @root
    ENV.delete("CF_KNOWN_REPO_ROOTS")
    ENV.delete("CF_INCIDENT_CLIENT_DIR")
    @shell = FakeShell.new
    @ocr_text = Hash.new("All systems normal")
    @ocr_ok = true
    @store = IncidentStore.new(repo: "shop-web", root: @root)
    @id = @store.create(slug: "bad-fixture", at: T0, client: "example-client")
  end

  def teardown
    %w[CF_SENSITIVE_TERMS_FILE CF_INCIDENTS_DIR CF_KNOWN_REPO_ROOTS CF_INCIDENT_CLIENT_DIR].each { |k| ENV.delete(k) }
    @prev.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(@tmp)
  end

  def ocr = IncidentReport::Ocr.new(runner: ->(path) { [ @ocr_text[File.basename(path)], @ocr_ok ] })

  def report(client_template: nil, ocr_override: nil, **opts)
    IncidentReport::Report.new(store: @store, id: @id, shell: @shell, ocr: ocr_override || ocr, client_template: client_template, known_roots: nil, **opts)
  end

  def sections(extra = {})
    { "impact" => "Analytics showed errors for two hours.", "timeline" => "10:00 reported. 11:00 fixed.",
      "fix" => "A test setting was removed.", "prevention" => "A release check now catches it." }.merge(extra)
  end

  def capture!(dir = File.join(@store.path(@id), "evidence"))
    shots = [ { "route" => "/status", "viewport" => "desktop", "png" => Base64.strict_encode64(PNG), "final_url" => "https://app.example.test/status" },
              { "route" => "/status", "viewport" => "mobile", "png" => Base64.strict_encode64(PNG + "m"), "final_url" => "https://app.example.test/status" } ]
    IncidentReport::Capture.run(browser: FakeBrowser.new("shots" => shots, "blocked" => [], "failed" => []), dir: dir,
                                base: "https://app.example.test", hosts: [ "app.example.test" ], routes: [ "/status" ],
                                viewports: IncidentReport::Capture.viewports("desktop,mobile"), masks: [], at: T1, version: "v1.2.1")
  end

  def shot_file(viewport, route) = "#{viewport}-#{IncidentReport::Capture.route_slug(route)}-#{IncidentReport.sha256(route)[0, 8]}.png"

  def ready!(rep = report)
    capture!
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    rep.finalize(at: T2)
  end

  # --- destination -----------------------------------------------------------

  def test_drafts_stay_in_the_incident_dir_when_no_destination_is_set
    rep = report
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    assert_equal File.join(@store.path(@id), "report", "out"), rep.manifest["dest"]
    assert File.file?(File.join(rep.manifest["dest"], "client-summary.md"))
  end

  def test_destination_override_expands_client_and_date
    rep = report(client_template: @client)
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    assert_equal File.join(@tmp, "notes", "example-client", "030226mon", @id), rep.manifest["dest"]
    assert File.file?(File.join(rep.manifest["dest"], "client-summary.md"))
  end

  def test_two_incidents_for_one_client_and_day_get_distinct_paths
    other_id = @store.create(slug: "second", at: T0, client: "example-client")
    other = IncidentReport::Report.new(store: @store, id: other_id, shell: @shell, ocr: ocr, client_template: @client, known_roots: nil)
    first = report(client_template: @client)
    first.draft(at: T1, sections: sections, title: "t")
    other.draft(at: T1, sections: sections("fix" => "Another."), title: "t")
    refute_equal first.manifest["dest"], other.manifest["dest"]
    assert_includes File.read(File.join(first.manifest["dest"], "client-summary.md")), "A test setting was removed."
  end

  def test_destination_refuses_a_git_work_tree_even_when_it_does_not_exist_yet
    repo = File.join(@tmp, "checkout")
    GitFixture.git_init(repo)
    err = assert_raises(IncidentStore::Invalid) do
      report(client_template: File.join(repo, "notes", "<client>")).draft(at: T1, sections: sections, title: "t")
    end
    assert_match(/inside a git work tree/, err.message)
  end

  def test_destination_needs_a_client_for_the_client_placeholder
    other = IncidentStore.new(repo: "shop-web", root: @root)
    id = other.create(slug: "no-client", at: T0)
    rep = IncidentReport::Report.new(store: other, id: id, shell: @shell, ocr: ocr, client_template: @client, known_roots: nil)
    err = assert_raises(IncidentReport::Error) { rep.draft(at: T1, sections: sections, title: "t") }
    assert_match(/needs <client>/, err.message)
  end

  def test_draft_renders_the_template_without_its_authoring_comment
    rep = report
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    text = File.read(File.join(rep.manifest["dest"], "client-summary.md"))
    assert_includes text, "# Analytics errors"
    assert_includes text, "## Impact\n\nAnalytics showed errors for two hours."
    refute_includes text, "<!--"
    refute_match(/\{\{/, text)
  end

  def test_draft_needs_every_section
    err = assert_raises(IncidentReport::Error) { report.draft(at: T1, sections: sections("fix" => " "), title: "t") }
    assert_match(/missing fix/, err.message)
  end

  # --- capture policy ---------------------------------------------------------

  def suite_file(tags: %w[read-only], steps: [ { "goto" => "/status" }, { "goto" => { "url" => "https://app.example.test/pricing?plan=a" } } ])
    path = File.join(@tmp, "ro.cf-testcases.yml")
    File.write(path, YAML.dump("suite" => "ro", "cases" => [ { "id" => "c1", "tags" => tags, "acceptance" => "reads", "steps" => steps } ]))
    path
  end

  def test_allowed_routes_come_from_read_only_cases_only
    assert_equal [ "/status", "/pricing?plan=a" ], IncidentReport::Capture.allowed_routes([ suite_file ])
    assert_empty IncidentReport::Capture.allowed_routes([ suite_file(tags: %w[smoke]) ])
  end

  def test_an_unlisted_route_is_refused
    err = assert_raises(IncidentReport::Capture::Refused) do
      IncidentReport::Capture.check!(routes: [ "/admin" ], allowed: [ "/status" ], session: nil, session_approved_by: nil)
    end
    assert_match(%r{not in the read-only suite allowlist: /admin}, err.message)
  end

  def test_capture_needs_a_read_only_suite
    err = assert_raises(IncidentReport::Capture::Refused) do
      IncidentReport::Capture.check!(routes: [ "/status" ], allowed: [], session: nil, session_approved_by: nil)
    end
    assert_match(/needs a read-only cf:qa suite/, err.message)
  end

  def test_an_admin_session_is_refused_without_approval
    err = assert_raises(IncidentReport::Capture::Refused) do
      IncidentReport::Capture.check!(routes: [ "/status" ], allowed: [ "/status" ], session: "admin", session_approved_by: " ")
    end
    assert_match(/session-approved-by/, err.message)
    IncidentReport::Capture.check!(routes: [ "/status" ], allowed: [ "/status" ], session: "admin", session_approved_by: "the owner")
  end

  def test_the_cli_refuses_an_http_url_a_missing_suite_and_an_unapproved_session
    base = [ "capture", "--repo", "shop-web", "--id", @id, "--routes", "/status", "--at", T1 ]
    cli = ->(*extra) { err = StringIO.new; code = IncidentReport::Cli.new(base + extra, out: StringIO.new, err: err, browser: FakeBrowser.new({}), env: @env).run; [ code, err.string ] }
    code, err = cli.call("--url", "http://app.example.test", "--suite", suite_file)
    assert_equal 1, code
    assert_match(/https production URL/, err)
    code, err = cli.call("--url", "https://app.example.test")
    assert_equal 1, code
    assert_match(/read-only cf:qa suite/, err)
    code, err = cli.call("--url", "https://app.example.test", "--suite", suite_file, "--session", "admin")
    assert_equal 1, code
    assert_match(/session-approved-by/, err)
  end

  def test_the_cli_captures_through_the_browser_and_records_it
    shots = [ { "route" => "/status", "viewport" => "desktop", "png" => Base64.strict_encode64(PNG), "final_url" => "https://app.example.test/status" } ]
    browser = FakeBrowser.new("shots" => shots, "blocked" => [ { "method" => "POST", "url" => "https://app.example.test/x", "reason" => "method POST" } ], "failed" => [])
    out = StringIO.new
    code = IncidentReport::Cli.new([ "capture", "--repo", "shop-web", "--id", @id, "--url", "https://app.example.test/", "--routes", "/status",
                                     "--suite", suite_file, "--viewports", "desktop", "--version", "v1.2.1", "--at", T1 ],
                                   out: out, err: StringIO.new, browser: browser, env: @env).run
    assert_equal 0, code, out.string
    assert_match(/1 screenshot\(s\), 1 request\(s\) blocked/, out.string)
    assert_includes browser.code, '"hosts":["app.example.test"]'
    record = JSON.parse(File.read(File.join(@store.path(@id), "evidence", "screens", "captures.json")))
    assert_equal true, record["read_only"]
    assert_equal "v1.2.1", record["version"]
  end

  def test_a_failed_capture_writes_no_screens
    dir = File.join(@tmp, "ev")
    browser = FakeBrowser.new("shots" => [], "blocked" => [], "failed" => [ { "route" => "/status", "viewport" => "desktop", "reason" => "redirect left the allowed hosts" } ])
    err = assert_raises(IncidentReport::Capture::Refused) do
      IncidentReport::Capture.run(browser: browser, dir: dir, base: "https://app.example.test", hosts: [ "app.example.test" ], routes: [ "/status" ],
                                  viewports: { "desktop" => [ 1, 1 ] }, masks: [], at: T1, version: "v")
    end
    assert_match(/redirect left the allowed hosts/, err.message)
    refute File.exist?(File.join(dir, "screens"))
  end

  # The browser module's policy, run under node against a fake page.
  HARNESS = <<~JS
    import fs from 'node:fs';
    const [, , modPath, scenarioJson] = process.argv;
    const scenario = JSON.parse(scenarioJson);
    const mod = await import(modPath);
    let handler = null;
    let current = 'about:blank';
    const events = [];
    const masked = [];
    const request = (spec) => ({
      method: () => spec.method, url: () => spec.url, isNavigationRequest: () => !!spec.nav, headers: () => ({ Accept: '*/*' }),
      continue: (over) => events.push({ url: spec.url, method: spec.method, outcome: 'continue', cookie: over && over.headers ? over.headers.Cookie : null }),
      abort: () => { events.push({ url: spec.url, method: spec.method, outcome: 'abort' }); spec.aborted = true; },
    });
    const page = {
      setRequestInterception: async () => {}, on: (_e, h) => { handler = h; }, evaluateOnNewDocument: async () => {},
      setExtraHTTPHeaders: async () => {}, setViewport: async () => {},
      evaluate: async (fn, arg) => {
        const el = (tag) => ({ tag, children: [], value: 'x', style: { setProperty(k, v) { (this.set ||= {})[k] = v; } },
                               querySelectorAll() { return this.children; } });
        const kid = el('span');
        const hit = el('img');
        hit.children = [ kid ];
        globalThis.NodeFilter = { SHOW_TEXT: 4 };
        globalThis.document = { body: {}, querySelectorAll: () => [ hit ], createTreeWalker: () => ({ nextNode: () => null }) };
        fn(arg);
        masked.push({ own: hit.style.set, child: kid.style.set, value: hit.value });
      },
      screenshot: async () => 'UE5H', url: () => current,
      goto: async (url) => {
        const plan = scenario.pages[new URL(url).pathname] || {};
        const nav = { method: 'GET', url, nav: true };
        const specs = [nav, ...(plan.requests || [])];
        for (const spec of specs) handler(request(spec));
        if (specs.some((s) => s.nav && s.aborted)) throw new Error('net::ERR_BLOCKED_BY_CLIENT');
        current = plan.final || url;
        return { status: () => plan.status || 200 };
      },
    };
    const out = await mod.default({ page });
    process.stdout.write(JSON.stringify({ result: out.data, events, masked }));
  JS

  def run_module(pages = {}, routes: [ "/status" ], cookie: nil, **named)
    skip "node is not installed" unless NODE
    pages = named if pages.empty?
    code = IncidentReport::Capture.module_source(base: "https://app.example.test", hosts: [ "app.example.test" ], routes: routes,
                                                 viewports: { "desktop" => [ 1440, 900 ] }, masks: IncidentReport::Capture::DEFAULT_MASKS, cookie: cookie)
    mod = File.join(@tmp, "mod.mjs")
    File.write(mod, code)
    harness = File.join(@tmp, "harness.mjs")
    File.write(harness, HARNESS)
    out, err, status = Open3.capture3("node", harness, mod, JSON.generate("pages" => pages))
    assert status.success?, err
    JSON.parse(out)
  end

  def test_the_page_cannot_post_the_request_is_aborted
    run = run_module("/status" => { "requests" => [ { "method" => "POST", "url" => "https://app.example.test/api/save" },
                                                    { "method" => "PUT", "url" => "https://app.example.test/api/save" },
                                                    { "method" => "HEAD", "url" => "https://app.example.test/static/a.css" } ] })
    outcome = ->(method) { run["events"].find { |e| e["method"] == method }["outcome"] }
    assert_equal "abort", outcome.call("POST")
    assert_equal "abort", outcome.call("PUT")
    assert_equal "continue", outcome.call("HEAD")
    assert_equal 1, run["result"]["shots"].size
    assert_equal [ "method POST", "method PUT" ], run["result"]["blocked"].map { |b| b["reason"] }
  end

  def test_masking_hides_the_matched_element_itself_not_just_its_children
    run = run_module("/status" => {})
    mask = run["masked"].first
    assert_equal "brightness(0)", mask["own"]["filter"]
    assert_equal "none", mask["own"]["background-image"]
    assert_equal "#000", mask["own"]["background"]
    assert_equal "hidden", mask["child"]["visibility"]
    assert_equal "", mask["value"]
  end

  def test_the_session_cookie_goes_only_to_the_production_origin
    code = IncidentReport::Capture.module_source(base: "https://app.example.test", hosts: [ "app.example.test", "cdn.example.test" ],
                                                 routes: [ "/status" ], viewports: { "desktop" => [ 1, 1 ] }, masks: [], cookie: "sid=abc")
    skip "node is not installed" unless NODE
    File.write(File.join(@tmp, "mod.mjs"), code)
    File.write(File.join(@tmp, "harness.mjs"), HARNESS)
    scenario = { "pages" => { "/status" => { "requests" => [ { "method" => "GET", "url" => "https://cdn.example.test/a.css" },
                                                                { "method" => "GET", "url" => "https://app.example.test/api/me" } ] } } }
    out, err, status = Open3.capture3("node", File.join(@tmp, "harness.mjs"), File.join(@tmp, "mod.mjs"), JSON.generate(scenario))
    assert status.success?, err
    cookies = JSON.parse(out)["events"].to_h { |e| [ e["url"], e["cookie"] ] }
    assert_equal "sid=abc", cookies["https://app.example.test/api/me"]
    assert_nil cookies["https://cdn.example.test/a.css"]
  end

  def test_a_production_url_with_a_nondefault_port_is_captured
    assert_equal "app.example.test:8443", IncidentReport::Capture.authority("https://app.example.test:8443/")
    assert_equal "app.example.test", IncidentReport::Capture.authority("https://app.example.test:443/")
    skip "node is not installed" unless NODE
    code = IncidentReport::Capture.module_source(base: "https://app.example.test:8443", hosts: [ "app.example.test:8443" ], routes: [ "/status" ],
                                                 viewports: { "desktop" => [ 1, 1 ] }, masks: [])
    File.write(File.join(@tmp, "mod.mjs"), code)
    File.write(File.join(@tmp, "harness.mjs"), HARNESS)
    out, err, status = Open3.capture3("node", File.join(@tmp, "harness.mjs"), File.join(@tmp, "mod.mjs"), JSON.generate("pages" => {}))
    assert status.success?, err
    assert_equal 1, JSON.parse(out)["result"]["shots"].size
  end

  def test_an_off_host_subresource_is_aborted_but_the_capture_succeeds
    run = run_module("/status" => { "requests" => [ { "method" => "GET", "url" => "https://tracker.example.net/p.gif" } ] })
    assert_equal "abort", run["events"].find { |e| e["url"].include?("tracker") }["outcome"]
    assert_empty run["result"]["failed"]
  end

  def test_an_off_host_redirect_fails_the_capture
    run = run_module("/status" => { "requests" => [ { "method" => "GET", "url" => "https://login.example.net/sso", "nav" => true } ],
                                    "final" => "https://login.example.net/sso" })
    assert_empty run["result"]["shots"]
    assert_match(/redirect left the allowed hosts: off-host login.example.net/, run["result"]["failed"].first["reason"])
  end

  def test_a_redirect_to_an_unlisted_same_host_route_fails
    run = run_module("/status" => { "final" => "https://app.example.test/login" })
    assert_empty run["result"]["shots"]
    assert_match(%r{unlisted route: /login}, run["result"]["failed"].first["reason"])
  end

  def test_an_http_error_status_fails_the_capture
    run = run_module("/status" => { "status" => 503 })
    assert_match(/http status 503/, run["result"]["failed"].first["reason"])
  end

  # --- states and receipts ----------------------------------------------------

  def test_draft_then_scan_roast_finalize_walks_the_states
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    assert_equal({ "summary" => "draft", "pdf" => "draft" }, rep.states)
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    assert_equal({ "summary" => "scanned", "pdf" => "scanned" }, rep.states)
    rep.roast(at: T1, repo_dir: @tmp)
    assert_equal({ "summary" => "roasted", "pdf" => "roasted" }, rep.states)
    report_json, problems = rep.finalize(at: T2)
    assert_empty problems
    assert_equal({ "summary" => "ready", "pdf" => "ready" }, rep.states)
    assert_equal true, report_json["ready"]
    summary = File.join(rep.manifest["dest"], "client-summary.md")
    assert_equal IncidentReport.sha256_file(summary), report_json.dig("drafts", "summary", "content_sha256")
    assert_equal 9, report_json.dig("drafts", "summary", "roast", "score")
  end

  def test_the_roast_bar_comes_from_roast_settings_not_a_literal
    rep = report
    ready!(rep)
    assert_equal 8.0, rep.manifest.dig("roast", "summary", "target")
    refute_match(/\b(?:target|bar)\s*[:=]\s*\d/, File.read(File.join(__dir__, "../scripts/incident_report.rb")))
  end

  def test_an_edit_after_finalize_drops_the_draft_back_to_draft
    rep = report
    ready!(rep)
    File.write(File.join(rep.manifest["dest"], "client-summary.md"), "# edited by hand\n")
    assert_equal "draft", rep.states["summary"]
    assert_equal "ready", rep.states["pdf"]
  end

  def test_an_edit_to_the_pdf_drops_only_the_pdf
    rep = report
    ready!(rep)
    File.binwrite(File.join(rep.manifest["dest"], "evidence.pdf"), "%PDF-tampered")
    assert_equal "draft", rep.states["pdf"]
    assert_equal "ready", rep.states["summary"]
  end

  def test_a_scan_failure_blocks_ready
    rep = report
    capture!
    rep.draft(at: T1, sections: sections("impact" => "The zorblax cluster failed."), title: "Analytics errors")
    rep.ocr_screens(at: T1)
    result = rep.scan(at: T1)
    refute result["summary"]["ok"]
    assert_equal "draft", rep.states["summary"]
    err = assert_raises(IncidentReport::Error) { rep.roast(at: T1, repo_dir: @tmp) }
    assert_match(/not scanned/, err.message)
    _report, problems = rep.finalize(at: T2)
    assert(problems.any? { |p| p.include?("summary: not scanned") })
  end

  def test_a_scan_hit_never_echoes_the_sensitive_term
    rep = report
    rep.draft(at: T1, sections: sections("fix" => "zorblax was removed. key AKIAABCDEFGHIJKLMNOP"), title: "t")
    out = StringIO.new
    code = IncidentReport::Cli.new([ "scan", "--repo", "shop-web", "--id", @id, "--at", T1 ], out: out, err: StringIO.new, env: @env).run
    assert_equal 1, code
    assert_includes out.string, "sensitive term in client-summary.md"
    assert_includes out.string, "aws access key in client-summary.md"
    refute_includes out.string, "zorblax"
  end

  def test_secret_patterns_are_found
    hits = IncidentReport::Scan.hits({ "a" => "Authorization: Bearer abcdefghijklmnopqrstuvwx", "b" => "password = hunter2hunter2" }, terms: [])
    assert_equal [ "bearer token", "credential assignment" ], hits.map { |h| h[:kind] }
  end

  def test_screenshot_ocr_text_is_scanned
    @ocr_text[shot_file("desktop", "/status")] = "Welcome back zorblax admin"
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    result = rep.scan(at: T1)
    refute result["pdf"]["ok"]
    assert_equal [ "ocr #{shot_file("desktop", "/status")}" ], result["pdf"]["hits"].map { |h| h[:source] }
    assert_equal "scanned", rep.states["summary"] # the summary itself is clean
  end

  def test_a_recapture_after_drafting_blocks_the_pdf_scan_until_redrafted
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    File.write(File.join(@store.path(@id), "evidence", "screens", "captures.json"), JSON.generate("shots" => [], "host" => "h", "version" => "v2"))
    result = rep.scan(at: T1)
    refute result["pdf"]["ok"]
    assert(result["pdf"]["notes"].any? { |n| n.include?("recaptured after the PDF was drafted") })
    assert_raises(IncidentReport::Error) { rep.roast(at: T1, repo_dir: @tmp) }
    assert_empty @shell.roast_calls
  end

  def test_scan_needs_current_ocr_for_every_screenshot
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    result = rep.scan(at: T1)
    refute result["pdf"]["ok"]
    assert(result["pdf"]["notes"].any? { |n| n.include?("no current OCR") })
  end

  def test_finalize_refuses_without_a_roast_receipt_matching_the_current_bytes
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    path = File.join(rep.manifest["dest"], "client-summary.md")
    File.write(path, "#{File.read(path)}\nOne more line.\n")
    rep.scan(at: T2)
    _report, problems = rep.finalize(at: T2)
    assert(problems.any? { |p| p.start_with?("summary: no roast receipt matches") })
    assert_equal "scanned", rep.states["summary"]
  end

  def test_finalize_refuses_without_any_roast_receipt
    rep = report
    rep.draft(at: T1, sections: sections, title: "t")
    rep.scan(at: T1)
    report_json, problems = rep.finalize(at: T2)
    assert_includes problems, "summary: no roast receipt matches the current bytes"
    assert_equal false, report_json["ready"]
  end

  def test_a_roast_below_the_bar_or_with_a_p0_blocks_ready_until_accepted
    @shell.score = 6
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    _r, problems = rep.finalize(at: T2)
    assert(problems.any? { |p| p.include?("below 8.0") })
    _r, problems = rep.finalize(at: T2, accept_below_bar: "Patrick reviewed it")
    assert_empty problems
    assert_equal "ready", rep.states["summary"]
  end

  def test_an_open_p0_blocks_ready_even_with_a_high_score
    @shell.p0 = 1
    rep = report
    rep.draft(at: T1, sections: sections, title: "t")
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    assert_equal "scanned", rep.states["summary"]
  end

  def test_roast_runs_roast_rb_with_text_for_the_summary_and_shots_for_the_pdf
    rep = report
    ready!(rep)
    summary, pdf = @shell.roast_calls
    assert_includes summary, "--text"
    refute_includes summary, "--shot"
    assert_equal 2, pdf.count("--shot")
    assert(@shell.roast_calls.all? { |c| c.include?("--kind") && c.include?("--brief") })
  end

  # Keeps the fake honest: the argv built here must satisfy the real roast.rb.
  def test_the_roast_argv_satisfies_the_real_roast_scripts_review_contract
    require_relative "../scripts/roast"
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    @shell.roast_calls.each do |argv|
      opts = Roast::Cli.parse(argv[2..] + [ "--estimate-only" ])
      review = Roast.resolve_review(flags: opts[:flags], storyboard: nil, config: opts[:config_review])
      Roast.check_review!(review)
      assert_equal IncidentReport::AUDIENCE, review[:audience]
      refute_empty review[:purpose]
      assert_includes Roast::KINDS, opts[:flags][:kind]
    end
  end

  def test_roast_needs_a_scan_first_scan_and_roast_come_after_drafting
    rep = report
    rep.draft(at: T1, sections: sections, title: "t")
    assert_raises(IncidentReport::Error) { rep.roast(at: T1, repo_dir: @tmp) }
    assert_empty @shell.roast_calls
  end

  # --- ocr ---------------------------------------------------------------------

  def test_without_ocr_the_pdf_cannot_be_ready_without_an_attestation
    @ocr_ok = false
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    assert_equal "unavailable", rep.ocr_screens(at: T1)["status"]
    assert rep.scan(at: T1)["pdf"]["ok"]
    rep.roast(at: T1, repo_dir: @tmp)
    _r, problems = rep.finalize(at: T2)
    assert(problems.any? { |p| p.include?("--attest-no-ocr") })
    assert_equal "roasted", rep.states["pdf"]
    report_json, problems = rep.finalize(at: T2, attest_no_ocr: "docker is down, Patrick checked the pages by eye")
    assert_empty problems
    assert_equal "docker is down, Patrick checked the pages by eye", report_json.dig("ocr_attestation", "reason")
    assert_equal "ready", rep.states["pdf"]
  end

  def test_final_pdf_page_ocr_is_scanned
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    @ocr_text["page-1.png"] = "footer leaks zorblax"
    _r, problems = rep.finalize(at: T2)
    assert(problems.any? { |p| p.start_with?("pdf: sensitive term in pdf page page-1.png") })
    refute(problems.any? { |p| p.include?("zorblax") })
    assert_equal "roasted", rep.states["pdf"]
  end

  def test_a_secret_on_a_readable_page_blocks_even_when_another_page_fails_ocr_and_is_attested
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    flaky = IncidentReport::Ocr.new(runner: ->(path) { File.basename(path) == "page-2.png" ? [ "boom", false ] : [ "password=extremelysecret", true ] })
    rep = report(ocr_override: flaky)
    _r, problems = rep.finalize(at: T2, attest_no_ocr: "page 2 is unreadable")
    assert(problems.any? { |p| p.start_with?("pdf: credential assignment in pdf page page-1.png") })
    assert_equal "roasted", rep.states["pdf"]
  end

  def test_a_secret_in_one_screenshot_is_kept_when_a_later_screenshot_fails_ocr
    first = shot_file("desktop", "/status")
    runner = ->(path) { File.basename(path) == first ? [ "password=extremelysecret", true ] : [ "no docker", false ] }
    rep = report(ocr_override: IncidentReport::Ocr.new(runner: runner))
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    assert_equal "unavailable", rep.ocr_screens(at: T1)["status"]
    result = rep.scan(at: T1)
    refute result["pdf"]["ok"]
    assert_equal [ "credential assignment" ], result["pdf"]["hits"].map { |h| h[:kind] }
    err = assert_raises(IncidentReport::Error) { rep.roast(at: T1, repo_dir: @tmp) }
    assert_match(/not scanned/, err.message)
    assert_empty @shell.roast_calls
  end

  def test_a_redraft_clears_the_human_exceptions_it_does_not_cover
    @ocr_ok = false
    @shell.score = 6
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "t")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
    rep.roast(at: T1, repo_dir: @tmp)
    _r, problems = rep.finalize(at: T2, attest_no_ocr: "no docker", accept_below_bar: "reviewed")
    assert_empty problems
    rep.draft(at: T2, sections: sections("fix" => "A different fix."), title: "t")
    refute rep.manifest.key?("ocr_attestation")
    refute rep.manifest.key?("accepted_below_bar")
    assert_equal({ "summary" => "draft", "pdf" => "draft" }, rep.states)
  end

  def test_a_very_long_route_still_gets_a_savable_filename
    route = "/search?q=#{'a' * 300}"
    shot = { "route" => route, "viewport" => "desktop", "png" => Base64.strict_encode64(PNG), "final_url" => "https://app.example.test/search" }
    record = IncidentReport::Capture.write(File.join(@tmp, "ev3"), { "shots" => [ shot ] }, base: "https://app.example.test", at: T1, version: "v")
    assert_operator record["shots"].first["file"].length, :<, 100
    assert File.file?(File.join(@tmp, "ev3", "screens", record["shots"].first["file"]))
  end

  def test_routes_that_normalize_to_one_slug_keep_separate_screenshots
    refute_equal shot_file("desktop", "/foo/bar"), shot_file("desktop", "/foo-bar")
    shots = [ "/foo/bar", "/foo-bar" ].map { |r| { "route" => r, "viewport" => "desktop", "png" => Base64.strict_encode64(PNG + r), "final_url" => "https://app.example.test#{r}" } }
    record = IncidentReport::Capture.write(File.join(@tmp, "ev2"), { "shots" => shots }, base: "https://app.example.test", at: T1, version: "v")
    assert_equal 2, record["shots"].map { |s| s["file"] }.uniq.size
    assert_equal 2, Dir[File.join(@tmp, "ev2", "screens", "*.png")].size
  end

  def test_the_ocr_container_is_pinned_and_runs_without_network
    assert_match(/@sha256:[0-9a-f]{64}\z/, IncidentReport::OCR_IMAGE)
    calls = []
    originals = { available?: ChangeDocker.method(:available?), run: ChangeDocker.method(:run) }
    ChangeDocker.define_singleton_method(:available?) { true }
    ChangeDocker.define_singleton_method(:run) { |**kw| calls << kw; [ "Estimating resolution as 90\ntext", Struct.new(:success?).new(true) ] }
    begin
      assert_equal [ "text", true ], IncidentReport::Ocr.new.read("/x/a.png")
    ensure
      originals.each { |name, original| ChangeDocker.define_singleton_method(name, original) }
    end
    assert_equal "none", calls.first[:network]
    assert_equal({ target: "/in", readonly: true }, calls.first[:mounts]["/x"])
    assert_equal IncidentReport::OCR_IMAGE, calls.first[:image]
  end

  # --- pdf ----------------------------------------------------------------------

  def test_the_pdf_footer_states_version_host_date_and_read_only
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    data = JSON.parse(File.read(File.join(rep.report_dir, "work", "evidence.json")))
    assert_equal "production v1.2.1 - app.example.test - captured 2026-03-02 - read-only", data["footer"]
    assert_equal [ "desktop: /status", "mobile: /status" ], data["shots"].map { |s| s["caption"] }
    assert_includes File.read(File.join(IncidentReport::TEMPLATES, "evidence-pdf.typ")), "#data.footer"
  end

  def test_a_missing_typst_is_refused_up_front_with_an_install_hint
    @shell.no_typst = true
    capture!
    err = assert_raises(IncidentReport::Error) { report.draft(at: T1, sections: sections, title: "t") }
    assert_match(/install typst/, err.message)
    refute(@shell.calls.any? { |c| c.first(2) == %w[typst compile] })
  end

  def test_the_pdf_is_built_with_plain_typst_compile
    capture!
    report.draft(at: T1, sections: sections, title: "t")
    assert(@shell.calls.any? { |c| c.first(2) == %w[typst compile] && c.last.end_with?("evidence.pdf") })
    refute(@shell.calls.flatten.include?("typstrb"))
  end

  def test_without_screenshots_only_the_summary_is_drafted
    rep = report
    rep.draft(at: T1, sections: sections, title: "t")
    assert_equal [ "summary" ], rep.manifest["drafts"].keys
  end

  def test_the_typst_template_compiles_for_real_when_typst_is_installed
    skip "typst is not installed" unless system("typst", "--version", out: File::NULL, err: File::NULL)
    work = File.join(@tmp, "typ")
    FileUtils.mkdir_p(work)
    File.binwrite(File.join(work, "a.png"), PNG)
    File.write(File.join(work, "evidence.json"), JSON.generate("title" => "t", "footer" => "production v1 - h - captured d - read-only",
                                                               "shots" => [ { "file" => "a.png", "caption" => "desktop: /" }, { "file" => "a.png", "caption" => "mobile: /" } ]))
    FileUtils.cp(File.join(IncidentReport::TEMPLATES, "evidence-pdf.typ"), File.join(work, "evidence.typ"))
    out, status = Open3.capture2e("typst", "compile", File.join(work, "evidence.typ"), File.join(work, "e.pdf"))
    assert status.success?, out
    assert_operator File.size(File.join(work, "e.pdf")), :>, 500
  end

  # --- no send ------------------------------------------------------------------

  def test_nothing_in_the_script_can_send_a_report
    source = File.read(File.join(__dir__, "../scripts/incident_report.rb"))
    refute_match(/net\/smtp|sendmail|Net::SMTP|slack|gmail|\bgh\s+(?:pr|issue)|--send\b|Net::HTTP\.(?:post|start)/i, source)
    out = StringIO.new
    IncidentReport::Cli.new([ "help" ], out: out, err: StringIO.new).run
    assert_includes out.string, "only a human sends it"
  end

  def test_status_prints_the_states
    rep = report
    rep.draft(at: T1, sections: sections, title: "t")
    out = StringIO.new
    code = IncidentReport::Cli.new([ "status", "--repo", "shop-web", "--id", @id ], out: out, err: StringIO.new, env: @env).run
    assert_equal 0, code
    assert_equal "summary: draft\n", out.string
  end

  def test_the_cli_runs_the_whole_flow_and_exits_nonzero_until_ready
    run = lambda do |*args|
      out = StringIO.new
      code = IncidentReport::Cli.new(args + [ "--repo", "shop-web", "--id", @id ], out: out, err: StringIO.new, shell: @shell, ocr: ocr, env: @env).run
      [ code, out.string ]
    end
    files = %w[impact timeline fix prevention].flat_map do |name|
      path = File.join(@tmp, "#{name}.txt")
      File.write(path, "Plain words about #{name}.")
      [ "--#{name}-file", path ]
    end
    assert_equal 0, run.call("draft", "--at", T1, "--title", "Analytics errors", *files).first
    assert_equal 0, run.call("scan", "--at", T1).first
    assert_equal 0, run.call("roast", "--at", T1, "--repo-dir", @tmp).first
    code, out = run.call("finalize", "--at", T2)
    assert_equal 0, code, out
    assert_match(/summary: ready/, out)
    assert_equal 2, run.call("bogus").first
  end

  # --- --project: the roast children get the resolved project ---

  def roast_cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = IncidentReport::Cli.new(args + [ "--repo", "shop-web", "--id", @id ], out: out, err: err, shell: @shell, ocr: ocr, env: @env).run
    [ code, err.string ]
  end

  def drafted_and_scanned
    rep = report
    capture!
    rep.draft(at: T1, sections: sections, title: "Analytics errors")
    rep.ocr_screens(at: T1)
    rep.scan(at: T1)
  end

  def test_roast_forwards_the_explicit_project_to_every_roast_child
    drafted_and_scanned
    project = File.realpath(@tmp)
    code, err = roast_cli("roast", "--at", T1, "--project", @tmp)
    assert_equal 0, code, err
    assert_equal 2, @shell.roast_calls.size
    @shell.roast_calls.each do |argv|
      assert_equal [ "--project", project ], argv.each_cons(2).find { |a, _| a == "--project" }
    end
  end

  def test_roast_forwards_the_cwd_when_it_is_an_ordinary_dir
    drafted_and_scanned
    code, err = roast_cli("roast", "--at", T1)
    assert_equal 0, code, err
    assert(@shell.roast_calls.all? { |argv| argv[argv.index("--project") + 1] == Dir.pwd })
  end

  def test_roast_from_a_scratchpad_without_project_leaves_the_children_to_decide
    scratch = make_scratchpad!
    drafted_and_scanned
    code, err = Dir.chdir(scratch) { roast_cli("roast", "--at", T1) }
    assert_equal 0, code, err
    assert_equal 2, @shell.roast_calls.size
    assert(@shell.roast_calls.none? { |argv| argv.include?("--project") })
  ensure
    remove_scratchpad!
  end

  def test_roast_project_naming_a_scratchpad_exits_2
    scratch = make_scratchpad!
    drafted_and_scanned
    code, err = roast_cli("roast", "--at", T1, "--project", scratch)
    assert_equal 2, code
    assert_includes err, "is a Claude Code session scratchpad"
    assert_empty @shell.roast_calls
  ensure
    remove_scratchpad!
  end
end
