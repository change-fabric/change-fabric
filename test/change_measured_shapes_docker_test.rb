# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_suite"

# The measured-verification shapes in a real browser: each browser-only bug
# class has a v5 case in test/fixtures/suites/measured/ that fails against its
# synthetic bad page and passes against its good page, so every shape is
# discriminating. Pages are served by request interception; no server, no
# network. Needs docker, and skips without it.
class ChangeMeasuredShapesDockerTest < Minitest::Test
  SUITES = File.expand_path("fixtures/suites/measured", __dir__)
  PAGES = File.expand_path("fixtures/measured", __dir__)

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  # Runs the named case against the good and the bad page in one browser.
  def verdicts(name)
    suite = ChangeSuite.load_file(File.join(SUITES, "#{name}.cf-testcases.yml"))
    assert_equal 5, suite.version, "measured shapes are suite v5"
    compiled = ChangeFlowCompiler.new(suite.cases.first.steps, base_url: "https://fixture.test").compile
    pages = %w[good bad].to_h { |kind| [ kind, File.read(File.join(PAGES, "#{name}.#{kind}.html")) ] }
    ChangeDocker.with_browserless(network: nil) do |session|
      pages.to_h { |kind, html| [ kind, run_flow(session, compiled, html)["steps"] ] }
    end
  end

  def run_flow(session, compiled, html)
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        await page.setRequestInterception(true);
        page.on("request", (request) => {
          // /data answers after 1.2 s, so it is in flight when the step runs.
          if (request.url().endsWith("/data")) return setTimeout(() => request.respond({ status: 200, contentType: "application/json", body: "{}" }), 1200);
          return request.respond({ status: 200, contentType: "text/html", body: #{JSON.generate(html)} });
        });
        const steps = await cfRunFlow(page, #{JSON.generate(compiled)});
        return { data: { steps: steps.map((s) => ({ ok: s.ok, error: s.error, label: s.label, durationMs: s.durationMs })) }, type: "application/json" };
      };
    JS
    session.run_function(code)
  end

  def assert_discriminates(name)
    result = verdicts(name)
    assert(result["good"].all? { |step| step["ok"] }, "good page should pass: #{result['good'].inspect}")
    failed = result["bad"].find { |step| !step["ok"] }
    refute_nil failed, "bad page should fail: #{result['bad'].inspect}"
    failed
  end

  def test_class_1_a_scroll_position_lost_on_return_fails
    assert_discriminates("scroll")
  end

  def test_class_2_a_layout_shift_after_load_fails_with_both_values
    failed = assert_discriminates("shift")
    assert_match(/moved from .* to .*tolerance 2px/, failed["error"])
  end

  # The header moves 20 px, then returns before the page settles: first against
  # last would pass; the whole window must not. max_cls is raised so only the
  # pixel excursion can fail it.
  def test_class_2_a_header_that_moves_and_returns_still_fails
    failed = assert_discriminates("excursion")
    assert_match(/moved from .* to .*deviation 2\d(\.\d+)?, tolerance 2px/, failed["error"])
  end

  # Inside a generous pixel tolerance, but the buffered layout-shift entries attribute
  # a shift to the header, and max_cls defaults to 0.
  def test_class_2_a_layout_shift_attributed_to_the_element_fails_max_cls
    failed = assert_discriminates("cls")
    assert_match(/layout shift .* attributed to main h1 exceeds max_cls 0/, failed["error"])
  end

  # The request is outstanding before expect_stable starts. Watching only from
  # that point would call the page idle after 500 ms and miss the shift.
  def test_class_2_a_shift_after_a_request_already_in_flight_fails
    assert_discriminates("inflight")
  end

  def test_class_3_a_sticky_bar_covering_the_first_row_fails
    assert_discriminates("sticky")
  end

  def test_class_4_a_control_clipped_to_zero_width_fails
    assert_discriminates("clipped")
  end

  def test_class_5_a_slow_interaction_fails_its_budget_with_the_measured_time
    failed = assert_discriminates("slow")
    assert_match(/span save\.\.step 3 took \d+ms, budget 1500ms/, failed["error"])
  end

  def test_every_step_records_a_duration
    result = verdicts("slow")
    assert(result["good"].all? { |step| step["durationMs"].is_a?(Integer) })
  end

  # --- suite v8: relations (C) ---------------------------------------------------------------

  # Runs one relation case against a table of routes. Each path maps to a list of
  # pages served on successive visits (the last repeats), so a count can be 69 on
  # the first load and 70 on the next.
  def run_routes(session, compiled, routes)
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        const routes = #{JSON.generate(routes)};
        const hits = {};
        await page.setRequestInterception(true);
        page.on("request", (request) => {
          const path = new URL(request.url()).pathname;
          const pages = routes[path];
          if (!pages) return request.respond({ status: 404, contentType: "text/plain", body: "no route " + path });
          hits[path] = (hits[path] || 0) + 1;
          return request.respond({ status: 200, contentType: "text/html", body: pages[Math.min(hits[path], pages.length) - 1] });
        });
        const steps = await cfRunFlow(page, #{JSON.generate(compiled)}, {});
        return { data: { steps: steps, hits: hits }, type: "application/json" };
      };
    JS
    session.run_function(code)
  end

  def v6_case(suite, id)
    loaded = ChangeSuite.load_file(File.join(SUITES, "#{suite}.cf-testcases.yml"))
    assert_equal 8, loaded.version, "relation shapes are suite v8"
    ChangeFlowCompiler.new(loaded.cases.find { |item| item.id == id }.steps, base_url: "https://fixture.test").compile
  end

  # The v5 pages, reached through the relation: each discriminates still.
  def assert_v6_discriminates(name, suite)
    compiled = v6_case("relation-#{suite}", suite_case_id(suite))
    result = ChangeDocker.with_browserless(network: nil) do |session|
      %w[good bad].to_h do |kind|
        html = File.read(File.join(PAGES, "#{name}.#{kind}.html"))
        [ kind, run_routes(session, compiled, { "/items" => [ html ], "/orders" => [ html ], "/search" => [ html ] })["steps"] ]
      end
    end
    assert(result["good"].all? { |step| step["ok"] }, "good page should pass: #{result['good'].inspect}")
    failed = result["bad"].find { |step| !step["ok"] }
    refute_nil failed, "bad page should fail: #{result['bad'].inspect}"
    [ result, failed ]
  end

  def suite_case_id(suite) = { "scroll" => "list-scroll-restores", "sticky" => "sticky-not-covering", "clipped" => "filter-button-usable" }.fetch(suite)

  def test_class_1_relation_a_scroll_position_lost_on_return_fails_the_relation
    _result, failed = assert_v6_discriminates("scroll", "scroll")
    assert_equal "expectRelation", failed["verb"]
    assert_match(/expected y_before = 1200 to equal y_after = 0 within 4/, failed["error"])
  end

  def test_class_3_relation_a_sticky_bar_covering_the_first_row_fails_the_le_relation
    _result, failed = assert_v6_discriminates("sticky", "sticky")
    assert_match(/expected bar_bottom = 60 <= row_top = 20 within 0/, failed["error"])
  end

  def test_class_4_relation_a_clipped_control_fails_the_minimum_size_relation
    _result, failed = assert_v6_discriminates("clipped", "clipped")
    assert_match(/expected 44 <= filter_w = 0 within 0/, failed["error"])
  end

  def admin_page(total, updated: "10:00", recent: %w[ada grace], admins: 3, guests: 67)
    "<!doctype html><title>Admin</title><span class='members-badge'>#{total} members</span> <span class='last-updated'>#{updated}</span>" \
      "<span class='role-admin'>#{admins}</span><span class='role-guest'>#{guests}</span>" \
      "<ul class='recent'>#{recent.map { |name| "<li>#{name}</li>" }.join}</ul>"
  end

  def members_page(count, updated: "10:00", names: nil)
    names ||= Array.new(count) { |n| "member#{n}" }
    "<!doctype html><title>Members</title><span class='last-updated'>#{updated}</span><table><tbody>" \
      "#{names.map { |name| "<tr><td class='name'>#{name}</td></tr>" }.join}</tbody></table>"
  end

  def count_run(id, routes)
    ChangeDocker.with_browserless(network: nil) do |session|
      run_routes(session, v6_case("count", id), routes)
    end
  end

  def test_class_6_a_count_that_agrees_on_both_surfaces_passes_clean
    routes = { "/admin" => [ admin_page(70) ], "/admin/members" => [ members_page(70) ] }
    steps = count_run("member-count-agrees", routes)["steps"]
    assert(steps.all? { |step| step["ok"] }, steps.inspect)
    relation = steps.last
    assert_equal "pass", relation["status"]
    refute relation["drift"]
    assert_equal %w[badge rows], relation["reads"].map { |read| read["var"] }
  end

  def test_class_6_a_69_that_becomes_70_on_the_reread_is_a_warning_with_drift
    routes = { "/admin" => [ admin_page(70, updated: "10:00"), admin_page(70, updated: "10:01") ],
               "/admin/members" => [ members_page(69, updated: "10:00"), members_page(70, updated: "10:01") ] }
    result = count_run("member-count-agrees", routes)
    relation = result["steps"].last
    assert relation["ok"], relation.inspect
    assert_equal "warn", relation["status"]
    assert relation["drift"]
    assert_equal [ 70, 69 ], relation["firstReads"].map { |read| read["value"] }
    assert_equal [ 70, 70 ], relation["reads"].map { |read| read["value"] }
    assert_match(/expected badge = 70 to equal rows = 69/, relation["firstMessage"])
    assert_operator result["hits"]["/admin"], :>=, 2, "the re-read went back to the first page"
    first, second = relation["firstReads"].map { |read| read["readAt"] }, relation["reads"].map { |read| read["readAt"] }
    assert_operator second.min, :>, first.max, "the re-read times are later than the first reads"
  end

  def test_class_6_a_69_that_stays_69_fails_with_both_value_sets
    routes = { "/admin" => [ admin_page(70) ], "/admin/members" => [ members_page(69) ] }
    relation = count_run("member-count-agrees", routes)["steps"].last
    refute relation["ok"]
    assert_equal "fail", relation["status"]
    assert_match(/expected badge = 70 to equal rows = 69 within 0 \(off by 1\); after re-read: expected badge = 70 to equal rows = 69/, relation["error"])
    assert_equal [ 70, 69 ], relation["firstReads"].map { |read| read["value"] }
    assert_equal [ 70, 69 ], relation["reads"].map { |read| read["value"] }
  end

  def test_class_6_without_settle_a_mismatch_fails_at_once_and_visits_each_page_once
    routes = { "/admin" => [ admin_page(70) ], "/admin/members" => [ members_page(69), members_page(70) ] }
    result = count_run("member-count-agrees-strict", routes)
    refute result["steps"].last["ok"]
    assert_equal({ "/admin" => 1, "/admin/members" => 1 }, result["hits"])
  end

  def test_a_list_that_is_a_subset_passes_and_one_with_a_stranger_fails
    ok = count_run("listed-members-are-known", { "/admin" => [ admin_page(2, recent: %w[ada grace]) ],
                                                 "/admin/members" => [ members_page(0, names: %w[grace ada linus]) ] })["steps"]
    assert(ok.all? { |step| step["ok"] }, ok.inspect)
    bad = count_run("listed-members-are-known", { "/admin" => [ admin_page(2, recent: %w[ada mallory]) ],
                                                  "/admin/members" => [ members_page(0, names: %w[grace ada linus]) ] })["steps"].last
    refute bad["ok"]
    assert_match(/missing \["mallory"\]/, bad["error"])
  end

  def test_an_empty_list_is_not_a_subset_of_anything_a_selector_that_matches_nothing_fails
    bad = count_run("listed-members-are-known", { "/admin" => [ admin_page(0, recent: []) ],
                                                  "/admin/members" => [ members_page(0, names: %w[grace]) ] })["steps"].last
    refute bad["ok"]
    assert_match(/recent to list items to find in everyone, but it is empty/, bad["error"])
  end

  def test_a_status_assertion_sees_the_navigation_a_precondition_made
    before = ChangeFlowCompiler.new([ { "goto" => "/admin" } ], base_url: "https://fixture.test").compile
    main = ChangeFlowCompiler.new([ { "expect_status" => 200 } ], base_url: "https://fixture.test", before: before).compile
    code = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      export default async ({ page }) => {
        await page.setRequestInterception(true);
        page.on("request", (request) => request.respond({ status: 200, contentType: "text/html", body: "<title>x</title>" }));
        const pre = await cfRunFlow(page, #{JSON.generate(before)});
        const steps = await cfRunFlow(page, #{JSON.generate(main)}, { lastResponse: pre.lastResponse });
        return { data: { steps: steps }, type: "application/json" };
      };
    JS
    steps = ChangeDocker.with_browserless(network: nil) { |session| session.run_function(code)["steps"] }
    assert(steps.all? { |step| step["ok"] }, steps.inspect)
  end

  def test_a_blank_text_figure_is_not_read_as_zero
    bad = count_run("blank-badge-is-not-zero", { "/admin" => [ "<!doctype html><title>Admin</title><span class='members-badge'> </span>" ] })["steps"].last
    refute bad["ok"]
    assert_match(/badge is empty; the figure was not rendered/, bad["error"])
  end

  def test_parts_that_sum_to_the_total_pass_and_parts_that_do_not_fail
    assert(count_run("parts-sum-to-total", { "/admin" => [ admin_page(70, admins: 3, guests: 67) ] })["steps"].all? { |step| step["ok"] })
    bad = count_run("parts-sum-to-total", { "/admin" => [ admin_page(70, admins: 3, guests: 60) ] })["steps"].last
    refute bad["ok"]
    assert_match(/the sum 63 of admins = 3, guests = 60/, bad["error"])
  end

  def test_every_capture_records_where_and_when_it_was_read
    routes = { "/admin" => [ admin_page(70) ], "/admin/members" => [ members_page(70) ] }
    capture = count_run("member-count-agrees", routes)["steps"].find { |step| step["captured"] == "rows" }
    assert_equal "https://fixture.test/admin/members", capture["url"]
    assert_equal "tbody tr", capture["selector"]
    assert_match(/\A\d{4}-\d\d-\d\dT/, capture["readAt"])
    assert_equal "10:00", capture["freshness"][".last-updated"]
  end
end
