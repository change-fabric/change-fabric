# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_config"
require_relative "../scripts/change_findings"
require_relative "../scripts/change_coverage"

# The QA coverage snapshot: route normalization, declared against exercised
# routes, the per-lane route cells, case counts against the selection, the
# null-not-zero rule for families a run did not measure, and that every key a
# record carries is one ChangeCoverageSchema names.
class ChangeCoverageTest < Minitest::Test
  BASE = "https://app.example.org"

  SUITE = <<~YAML
    suite: claims
    cases:
      - id: submit
        tags: [smoke]
        acceptance: A claim can be submitted.
        steps:
          - goto: /claims
          - goto: { url: "#{BASE}/claims/new?step=1" }
          - click: "#submit"
          - expect_url: { contains: "/claims/done" }
      - id: history
        tags: [slow]
        acceptance: Past claims are listed.
        steps:
          - goto: /history
  YAML

  def setup
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, "claims.cf-testcases.yml"), SUITE)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def lanes_raw
    {
      "k6" => { "enabled" => true },
      "a11y" => { "routes" => %w[/ /claims/] },
      "browserless" => { "routes" => [ "/claims", { "path" => "/profile" } ],
                         "viewports" => [ { "name" => "mobile", "width" => 390, "height" => 844 },
                                          { "name" => "desktop", "width" => 1440, "height" => 900 } ] },
      "zap" => { "targets" => [ "/login", "#{BASE}/admin", "https://foreign.example.net/x" ] },
      "testcases" => { "suites" => [ "*.cf-testcases.yml" ],
                       "auth" => { "login_url" => "/login?next=/claims" } }
    }
  end

  def config(lanes = lanes_raw)
    ChangeConfig.new({ "project" => "fixture-app", "boot" => { "target_url" => BASE }, "lanes" => lanes }, @dir)
  end

  def suite_set = ChangeSuiteSet.load([ "*.cf-testcases.yml" ], @dir)

  def finding(lane, status, location: "", target: BASE, severity: "medium")
    Finding.new(lane: lane, check: "check", status: status, location: location, target: target, severity: severity)
  end

  def case_record(id, status, gotos: [], landed: nil, **extra)
    { "source" => "testcases", "suite" => "claims", "id" => id, "status" => status, "gated" => true,
      "attempts" => 1, "flaky" => false, "duration_ms" => nil, "tags" => [], "message" => nil,
      "acceptance_verdict" => nil, "quarantine" => nil, "gotos_reached" => gotos,
      "landed_url" => landed }.merge(extra.transform_keys(&:to_s))
  end

  def ids = { id: "20261013T141500Z-1a2b3c4-run", sweep_id: "20261013T141500Z-1a2b3c4",
              recorded_at: Time.utc(2026, 10, 13, 14, 15, 0) }

  def git = { branch: "main", sha: "1a2b3c4d5e", short_sha: "1a2b3c4", subject: "Fix the form",
              pr: { number: 42, url: "https://example.invalid/pr/42" }, trunk: true }

  def snapshot(lanes_ran:, findings: [], records: [], selection: nil, cfg: config, imports: nil, suites: suite_set)
    ChangeCoverage.snapshot(config: cfg, lanes_ran: lanes_ran, findings: findings, case_records: records,
                            suite_set: suites, selection: selection, git: git, ids: ids,
                            toolkit: "skills/v1.0.0", repo: { root: "#{Dir.home}/code/fixture-app",
                                                              origin: "https://user:token@example.invalid/org/app.git" },
                            imports: imports)
  end

  def route(run, path) = run["routes"]["items"].find { |item| item["path"] == path }

  # --- normalization --------------------------------------------------------------

  def test_route_normalization
    table = {
      "/" => "/", "" => nil, "claims" => "/claims", "/claims/" => "/claims", "/claims?x=1#top" => "/claims",
      "#{BASE}" => "/", "#{BASE}/" => "/", "#{BASE}/claims/?page=2" => "/claims",
      "HTTPS://APP.EXAMPLE.ORG/Claims" => "/Claims", "https://foreign.example.net/claims" => nil,
      "/a//" => "/a"
    }
    table.each do |input, expected|
      actual = ChangeCoverage::Routes.normalize(input, base_url: BASE)
      expected.nil? ? assert_nil(actual, input) : assert_equal(expected, actual, input)
    end
  end

  def test_an_absolute_url_keeps_its_path_when_no_base_is_known
    assert_equal "/claims", ChangeCoverage::Routes.normalize("https://any.example.net/claims")
  end

  # A base with a path prefix: an absolute url keeps only the route below the
  # base path, the base itself is `/`, and the prefix is stripped only on a
  # path boundary.
  def test_an_absolute_url_under_a_base_path_drops_the_base_path
    base = "https://host.example/app"
    table = {
      "#{base}/claims" => "/claims", "#{base}/claims/?x=1" => "/claims", base => "/", "#{base}/" => "/",
      "#{base}?next=1" => "/", "https://host.example/application/x" => "/application/x",
      "https://host.example/other" => "/other", "claims" => "/claims"
    }
    table.each { |input, expected| assert_equal expected, ChangeCoverage::Routes.normalize(input, base_url: base), input }
    assert_equal "/claims", ChangeCoverage::Routes.normalize("#{base}/claims", base_url: "#{base}/")
    assert_nil ChangeCoverage::Routes.normalize("https://host.example.evil.example/app/x", base_url: base)
  end

  # One page reached through every lane under a base with a path prefix is one
  # route: the zap target, its finding and the suite goto all land on /claims.
  def test_a_base_path_prefix_keeps_one_route_across_lanes
    base = "https://host.example/app"
    File.write(File.join(@dir, "claims.cf-testcases.yml"), <<~YAML)
      suite: claims
      cases:
        - id: open
          acceptance: The claims list opens.
          steps:
            - goto: #{base}/claims
    YAML
    lanes = { "a11y" => { "routes" => [ "/claims" ] }, "zap" => { "targets" => [ "claims" ] },
              "testcases" => { "suites" => [ "*.cf-testcases.yml" ] } }
    cfg = ChangeConfig.new({ "project" => "fixture-app", "boot" => { "target_url" => base }, "lanes" => lanes }, @dir)
    run = snapshot(lanes_ran: %w[a11y zap testcases], cfg: cfg,
                   findings: [ finding("zap", "fail", target: "#{base}/claims") ])

    assert_equal [ "/claims" ], run["routes"]["items"].map { |item| item["path"] }
    assert_equal "fail", route(run, "/claims")["lane_status"]["zap"]
    assert_equal [ "claims/open" ], route(run, "/claims")["cases_static"]
    assert_equal 0, run["routes"]["undeclared_exercised"]
  end

  # --- declared and exercised ---------------------------------------------------------

  def test_declared_routes_come_from_a11y_browserless_and_zap
    run = snapshot(lanes_ran: %w[a11y browserless zap])
    declared = run["routes"]["items"].select { |item| item["declared"] }.to_h { |item| [ item["path"], item["declared_by"] ] }

    assert_equal({ "/" => %w[a11y], "/claims" => %w[a11y browserless], "/profile" => %w[browserless],
                   "/login" => %w[zap], "/admin" => %w[zap] }, declared)
    assert_equal 5, run["routes"]["declared_total"]
  end

  def test_browserless_routes_cross_its_viewports
    run = snapshot(lanes_ran: %w[browserless])

    assert_equal %w[mobile desktop], route(run, "/profile")["viewports"]
    assert_equal [], route(run, "/admin")["viewports"]
  end

  def test_browserless_falls_back_to_its_default_viewports_and_routes
    lanes = lanes_raw.merge("browserless" => {})
    run = snapshot(lanes_ran: %w[browserless], cfg: config(lanes))

    assert_equal %w[mobile tablet desktop], route(run, "/")["viewports"]
  end

  def test_a_disabled_lane_declares_nothing
    lanes = lanes_raw.merge("zap" => lanes_raw["zap"].merge("enabled" => false))
    run = snapshot(lanes_ran: %w[a11y], cfg: config(lanes))

    assert_nil route(run, "/admin")
  end

  def test_static_and_runtime_case_routes_are_exercised_and_undeclared_ones_counted
    records = [ case_record("claims/submit", "pass", gotos: %w[/claims /claims/new], landed: "/claims/done") ]
    run = snapshot(lanes_ran: %w[testcases], records: records)
    routes = run["routes"]

    assert_equal %w[claims/submit], route(run, "/claims")["cases_static"]
    assert_equal %w[claims/submit], route(run, "/claims")["cases_reached"]
    assert_equal %w[claims/submit], route(run, "/claims/done")["cases_reached"]
    assert_equal [], route(run, "/login")["cases_static"]
    refute route(run, "/claims/new")["declared"]
    # /claims and /login are declared and exercised; /claims/new, /claims/done
    # and /history are exercised by cases but declared by no lane.
    assert_equal 2, routes["declared_exercised"]
    assert_equal 3, routes["undeclared_exercised"]
  end

  def test_static_gotos_count_only_when_the_testcases_lane_ran
    run = snapshot(lanes_ran: %w[a11y])

    assert_nil route(run, "/history")
    assert_equal 0, run["routes"]["undeclared_exercised"]
  end

  def test_expect_url_fragments_are_not_routes
    run = snapshot(lanes_ran: %w[testcases], records: [])

    assert_nil route(run, "/claims/done")
  end

  # --- cells -----------------------------------------------------------------------

  def test_lane_cells
    findings = [ finding("a11y", "warn", location: "/claims .btn > span"), finding("a11y", "pass", location: "/claims"),
                 finding("browserless", "fail", location: "/claims"), finding("zap", "pass", target: "#{BASE}/login") ]
    records = [ case_record("claims/submit", "fail", gotos: %w[/claims]), case_record("claims/other", "pass", gotos: %w[/claims]) ]
    run = snapshot(lanes_ran: %w[a11y browserless zap testcases], findings: findings, records: records)

    assert_equal({ "k6" => "lane_off", "a11y" => "warn", "zap" => "not_declared", "browserless" => "fail",
                   "testcases" => "fail" }, route(run, "/claims")["lane_status"])
    assert_equal "pass", route(run, "/login")["lane_status"]["zap"]
    assert_equal "no_result", route(run, "/login")["lane_status"]["testcases"]
    assert_equal "no_result", route(run, "/admin")["lane_status"]["zap"]
    assert_equal "not_declared", route(run, "/admin")["lane_status"]["testcases"]
    assert_equal "no_result", route(run, "/profile")["lane_status"]["browserless"]
  end

  def test_k6_is_not_applicable_per_route_when_it_ran
    run = snapshot(lanes_ran: %w[k6 a11y])

    assert_equal "n_a", route(run, "/")["lane_status"]["k6"]
    assert_equal "lane_off", route(run, "/")["lane_status"]["testcases"]
  end

  # --- lanes, cases, findings ------------------------------------------------------------

  def test_lane_results_count_findings_per_lane
    findings = [ finding("a11y", "pass"), finding("a11y", "warn", severity: "medium"),
                 finding("a11y", "fail", severity: "high"), finding("zap", "pass") ]
    run = snapshot(lanes_ran: %w[a11y zap], findings: findings)
    lanes = run["lanes"]

    assert_equal ChangeSchema::LANES, lanes["configured"]
    assert_equal %w[k6 a11y zap browserless testcases], lanes["enabled"]
    assert_equal %w[a11y zap], lanes["ran"]
    assert_equal({ "status" => "fail", "findings" => { "pass" => 1, "warn" => 1, "fail" => 1 },
                   "by_severity" => { "high" => 1, "medium" => 1 } }, lanes["results"]["a11y"])
    assert_equal "pass", lanes["results"]["zap"]["status"]
    assert_equal({ "pass" => 2, "warn" => 1, "fail" => 1 }, run["findings"])
  end

  def test_case_counts
    records = [ case_record("claims/a", "pass", flaky: true, attempts: 2), case_record("claims/b", "fail"),
                case_record("claims/c", "warn", gated: false,
                            quarantine: { "reason" => "flake", "until" => "2026-12-01", "expired" => false }),
                case_record("claims/d", "fail", quarantine: { "reason" => "old", "until" => "2026-01-01", "expired" => true }),
                case_record("claims/e", "error"), case_record("claims/f", "skip") ]
    cases = snapshot(lanes_ran: %w[testcases], records: records)["cases"]

    assert_equal({ "pass" => 1, "fail" => 2, "error" => 1, "skip" => 1, "warn" => 1, "flaky" => 1,
                   "quarantined" => 1, "ungated" => 1 }, cases["counts"])
    assert_equal 6, cases["items"].size
    refute cases["truncated"]
  end

  def test_selection_narrows_selected_total_without_shrinking_defined_total
    all = snapshot(lanes_ran: %w[testcases])["cases"]
    narrowed = snapshot(lanes_ran: %w[testcases], selection: { suites: [], tags: [ "smoke" ] })
    by_suite = snapshot(lanes_ran: %w[testcases], selection: { "suites" => [ "slow" ], "tags" => [] })

    assert_equal [ 2, 2 ], all.values_at("defined_total", "selected_total")
    assert_equal [ 2, 1 ], narrowed["cases"].values_at("defined_total", "selected_total")
    assert_equal [ 2, 1 ], by_suite["cases"].values_at("defined_total", "selected_total")
    assert_equal({ "suites" => [], "tags" => [ "smoke" ] }, narrowed["selection"])
    assert_equal 2, narrowed["suite_inventory"].size
    assert_nil route(narrowed, "/history")
  end

  def test_case_items_are_capped_with_counts_kept_whole
    cap = ChangeCoverageSchema::MAX_CASE_ITEMS
    records = Array.new(cap + 2) { |index| case_record("claims/c#{index}", "pass") }
    cases = snapshot(lanes_ran: %w[testcases], records: records)["cases"]

    assert_equal cap, cases["items"].size
    assert cases["truncated"]
    assert_equal cap + 2, cases["counts"]["pass"]
  end

  def test_suite_inventory_lists_every_defined_case
    run = snapshot(lanes_ran: %w[a11y])

    assert_equal [ { "suite" => "claims", "id" => "claims/submit", "tags" => [ "smoke" ] },
                   { "suite" => "claims", "id" => "claims/history", "tags" => [ "slow" ] } ], run["suite_inventory"]
  end

  # --- null, not zero ------------------------------------------------------------------

  def test_families_a_run_did_not_measure_are_null
    run = snapshot(lanes_ran: [], suites: nil)

    assert_nil run["routes"]
    assert_nil run["cases"]
    assert_nil run["findings"]
    assert_nil run["imports"]
    assert_nil run["suite_inventory"]
    assert_equal({}, run["lanes"]["results"])
  end

  def test_cases_are_null_when_the_testcases_lane_did_not_run
    assert_nil snapshot(lanes_ran: %w[a11y])["cases"]
  end

  def test_imports_split_by_format
    summaries = [ { "label" => "unit", "format" => "jacoco", "line" => { "covered" => 8, "total" => 10 },
                    "branch" => nil, "warnings" => [ "x" ] },
                  { label: "ui", format: "testng", counts: { "pass" => 1 } } ]
    imports = snapshot(lanes_ran: %w[a11y], imports: summaries)["imports"]

    assert_equal [ "unit" ], imports["coverage"].map { |entry| entry["label"] }
    assert_equal [ "ui" ], imports["test_results"].map { |entry| entry["label"] }
    refute imports["coverage"].first.key?("warnings")
  end

  def test_an_import_run_carries_only_imports
    run = ChangeCoverage.import_run(summaries: [ { "label" => "unit", "format" => "junit", "counts" => {} } ],
                                    git: git, ids: ids.merge(id: "x-import-junit-unit"), toolkit: "t",
                                    repo: { root: "/srv/app", origin: nil }, profile: "ci")

    assert_equal %w[import import], run.values_at("source", "scope")
    %w[lanes routes cases suite_inventory findings selection].each { |key| assert_nil run[key], key }
    assert_equal 1, run["imports"]["test_results"].size
    assert_equal [], run["imports"]["coverage"]
    assert_equal "ci", run["profile"]
  end

  # --- identity --------------------------------------------------------------------------

  def test_identity_fields
    run = snapshot(lanes_ran: %w[a11y])

    assert_equal 1, run["schema"]
    assert_equal "2026-10-13T14:15:00Z", run["recorded_at"]
    assert_equal({ "root" => "~/code/fixture-app", "origin" => "https://example.invalid/org/app.git" }, run["repo"])
    assert_equal({ "number" => 42, "url" => "https://example.invalid/pr/42" }, run["git"]["pr"])
    assert_equal true, run["git"]["trunk"]
  end

  # --- schema --------------------------------------------------------------------------

  def test_every_emitted_key_is_in_the_schema
    findings = [ finding("a11y", "warn", location: "/claims"), finding("zap", "fail", target: "#{BASE}/login", severity: "high") ]
    records = [ case_record("claims/submit", "pass", gotos: %w[/claims]) ]
    imports = [ { "label" => "unit", "format" => "jacoco", "file" => "j.xml", "line" => { "covered" => 1, "total" => 2 },
                  "branch" => { "covered" => 1, "total" => 2 },
                  "groups" => [ { "name" => "com/example/fixture", "line" => { "covered" => 1, "total" => 2 },
                                  "branch" => nil } ],
                  "groups_truncated" => false, "timestamp" => "2026-10-13T13:58:02Z", "stale" => false } ]
    runs = [ snapshot(lanes_ran: ChangeSchema::LANES, findings: findings, records: records, imports: imports),
             ChangeCoverage.import_run(summaries: imports, git: git, ids: ids, toolkit: "t", repo: nil) ]
    runs.each do |run|
      dotted(run).each { |path| assert known?(path), "#{path} is not in ChangeCoverageSchema::FIELDS" }
    end
  end

  ITEM_LISTS = %w[cases.items imports.test_results[].items].freeze

  # A path is known when FIELDS names it, or when it is a null or empty
  # container FIELDS names the members of.
  def known?(path)
    ChangeCoverageSchema::FIELDS.any? { |field| field == path || field.start_with?("#{path}.", "#{path}[]") }
  end

  # Dotted leaf paths in the FIELDS convention: `[]` per list item, a lane or
  # severity key as its placeholder, and a list of per-case records as one
  # `items[]` entry.
  def dotted(value, prefix = nil)
    case value
    when Hash
      return [ prefix ] if value.empty?

      value.flat_map { |key, child| dotted(child, join(prefix, placeholder(prefix, key))) }
    when Array
      return [ "#{prefix}[]" ] if ITEM_LISTS.include?(prefix)
      return [ prefix ] if value.none? { |item| item.is_a?(Hash) }

      value.flat_map { |item| dotted(item, "#{prefix}[]") }.uniq
    else
      [ prefix ]
    end
  end

  def placeholder(prefix, key)
    return "<lane>" if %w[lanes.results routes.items[].lane_status].include?(prefix)
    return "<severity>" if prefix.to_s.end_with?(".by_severity")

    key.to_s
  end

  def join(prefix, key) = prefix ? "#{prefix}.#{key}" : key
end
