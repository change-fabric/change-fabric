# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_lane_browserless"

# Covers the shared flow compiler: every action and assertion verb, the raw-JS
# escape hatch and its distinct marking, the refusal of malformed steps, the
# rule that a secret read from an env var never reaches a redacted view, and a
# golden check that the browserless lane's login payload is byte-identical to
# what the lane emitted before the compiler was extracted out of it.
#
# The compiled JS itself is exercised by a real docker+browserless run, not
# here: it needs a live Chromium page. What is testable in pure Ruby is the
# compilation, and that is what determinism actually rests on.
class ChangeFlowCompilerTest < Minitest::Test
  ENV_FIXTURE = { "QA_EMAIL" => "user@example.org", "QA_PASSWORD" => "hunter2" }.freeze

  def compile(steps, base_url: "https://app.example.org")
    ChangeFlowCompiler.new(steps, base_url: base_url, env: ENV_FIXTURE).compile
  end

  def one(step) = compile([ step ]).first

  # --- actions ------------------------------------------------------------------

  def test_goto_resolves_a_relative_path_against_the_base_url
    step = one("goto" => "/products/widget")
    assert_equal "goto", step[:verb]
    assert_equal "https://app.example.org/products/widget", step[:url]
    assert_equal "domcontentloaded", step[:waitUntil]
  end

  def test_goto_leaves_an_absolute_url_alone_and_honors_an_explicit_wait_until
    step = one("goto" => { "url" => "https://other.example.org/x", "wait_until" => "load" })
    assert_equal "https://other.example.org/x", step[:url]
    assert_equal "load", step[:waitUntil]
  end

  def test_click_takes_the_scalar_shorthand
    step = one("click" => "[data-test=add-to-cart]")
    assert_equal "click", step[:verb]
    assert_equal "[data-test=add-to-cart]", step[:selector]
  end

  def test_fill_from_a_literal_value
    step = one("fill" => { "selector" => "#q", "value" => "widget" })
    assert_equal "fill", step[:verb]
    assert_equal "widget", step[:value]
    refute step[:secret]
  end

  def test_fill_from_env_resolves_on_the_host_and_is_marked_secret
    step = one("fill" => { "selector" => "#email", "env" => "QA_EMAIL" })
    assert_equal "user@example.org", step[:value]
    assert_equal true, step[:secret]
  end

  def test_fill_from_a_code_source_carries_the_url_and_never_resolves_it_on_the_host
    step = one("fill" => { "selector" => "#otp",
                           "code_source" => { "url" => "http://mailpit:8025/latest", "pattern" => '(\d{6})' } })
    assert_equal "http://mailpit:8025/latest", step[:codeSource][:url]
    assert_equal 20_000, step[:codeSource][:timeoutMs]
    assert_equal 1_000, step[:codeSource][:pollIntervalMs]
    refute step.key?(:value)
  end

  def test_fill_refuses_two_value_sources
    error = assert_raises(ChangeFlowCompiler::Error) do
      compile([ { "fill" => { "selector" => "#email", "env" => "QA_EMAIL", "value" => "literal" } } ])
    end
    assert_includes error.message, "more than one value source"
  end

  def test_fill_refuses_no_value_source
    assert_raises(ChangeFlowCompiler::Error) { compile([ { "fill" => { "selector" => "#email" } } ]) }
  end

  def test_select_carries_the_option_value
    step = one("select" => { "selector" => "#country", "value" => "NZ" })
    assert_equal "select", step[:verb]
    assert_equal "NZ", step[:value]
  end

  def test_press_takes_a_bare_key_or_a_focused_selector
    assert_equal "Enter", one("press" => "Enter")[:key]
    focused = one("press" => { "key" => "Enter", "selector" => "#q" })
    assert_equal "#q", focused[:selector]
    assert_includes focused[:label], "#q"
  end

  def test_wait_for_accepts_a_selector_a_url_fragment_or_a_load_state
    assert_equal "#ready", one("wait_for" => "#ready")[:selector]
    assert_equal "/done", one("wait_for" => { "url_contains" => "/done" })[:urlContains]
    assert_equal "load", one("wait_for" => { "state" => "load" })[:state]
  end

  def test_wait_for_refuses_two_conditions
    error = assert_raises(ChangeFlowCompiler::Error) do
      compile([ { "wait_for" => { "selector" => "#a", "url_contains" => "/b" } } ])
    end
    assert_includes error.message, "more than one condition"
  end

  def test_screenshot_names_itself
    assert_equal "cart", one("screenshot" => "cart")[:name]
    assert_equal "screenshot", one("screenshot" => {})[:name]
  end

  # --- assertions -----------------------------------------------------------------

  def test_expect_visible_and_expect_hidden
    assert_equal "expectVisible", one("expect_visible" => "#cart")[:verb]
    assert_equal "expectHidden", one("expect_hidden" => "#spinner")[:verb]
    assert_equal "#spinner", one("expect_hidden" => "#spinner")[:selector]
  end

  def test_expect_text_equals_and_contains
    equals = one("expect_text" => { "selector" => "#count", "equals" => "1" })
    assert_equal "1", equals[:equals]
    assert_nil equals[:contains]
    contains = one("expect_text" => { "selector" => "#msg", "contains" => "thanks" })
    assert_equal "thanks", contains[:contains]
    assert_nil contains[:equals]
  end

  def test_expect_text_refuses_both_match_modes
    error = assert_raises(ChangeFlowCompiler::Error) do
      compile([ { "expect_text" => { "selector" => "#c", "equals" => "1", "contains" => "1" } } ])
    end
    assert_includes error.message, "both equals and contains"
  end

  def test_expect_url_takes_the_scalar_shorthand_as_contains
    step = one("expect_url" => "/confirmation")
    assert_equal "expectUrl", step[:verb]
    assert_equal "/confirmation", step[:contains]
  end

  def test_expect_status_coerces_to_an_integer
    assert_equal 200, one("expect_status" => "200")[:equals]
    assert_equal 404, one("expect_status" => { "equals" => 404 })[:equals]
  end

  def test_expect_count_needs_a_selector_and_a_count
    step = one("expect_count" => { "selector" => "li.item", "equals" => 3 })
    assert_equal 3, step[:equals]
    assert_equal "li.item", step[:selector]
    assert_raises(ChangeFlowCompiler::Error) { compile([ { "expect_count" => { "selector" => "li" } } ]) }
  end

  # --- the escape hatch --------------------------------------------------------------

  def test_eval_is_compiled_and_marked_as_raw_js
    step = one("eval" => "return document.title;")
    assert_equal "eval", step[:verb]
    assert_equal "return document.title;", step[:script]
    assert_equal true, step[:raw]
    assert_includes step[:label], "raw JS"
    assert_includes step[:label], "declarative contract"
  end

  def test_eval_steps_are_reportable_apart_from_declarative_ones
    compiler = ChangeFlowCompiler.new([ { "click" => "#go" }, { "eval" => "return 1;" } ], env: ENV_FIXTURE)
    assert compiler.uses_eval?
    assert_equal 1, compiler.eval_steps.size
    assert_equal "eval", compiler.eval_steps.first[:verb]
  end

  def test_a_flow_without_eval_is_not_marked_raw
    refute ChangeFlowCompiler.new([ { "click" => "#go" } ], env: ENV_FIXTURE).uses_eval?
  end

  # --- malformed steps ------------------------------------------------------------

  def test_an_unknown_verb_is_refused_by_name
    error = assert_raises(ChangeFlowCompiler::Error) { compile([ { "hover" => "#x" } ]) }
    assert_includes error.message, "hover"
  end

  def test_two_verbs_in_one_step_are_refused
    error = assert_raises(ChangeFlowCompiler::Error) { compile([ { "click" => "#a", "goto" => "/b" } ]) }
    assert_includes error.message, "more than one verb"
  end

  def test_a_non_mapping_step_is_refused
    assert_raises(ChangeFlowCompiler::Error) { compile([ "click #go" ]) }
  end

  def test_a_step_level_timeout_overrides_the_flow_default
    steps = ChangeFlowCompiler.new([ { "click" => "#a", "timeout_ms" => 500 }, { "click" => "#b" } ],
                                   timeout_ms: 9_000, env: ENV_FIXTURE).compile
    assert_equal 500, steps.first[:timeoutMs]
    assert_equal 9_000, steps.last[:timeoutMs]
  end

  # --- secret redaction ------------------------------------------------------------

  def test_redacted_replaces_an_env_sourced_value_and_leaves_the_rest
    compiler = ChangeFlowCompiler.new([ { "fill" => { "selector" => "#email", "env" => "QA_EMAIL" } },
                                        { "fill" => { "selector" => "#q", "value" => "widget" } } ],
                                      env: ENV_FIXTURE)
    redacted = compiler.redacted
    assert_equal ChangeFlowCompiler::REDACTED, redacted.first[:value]
    assert_equal "widget", redacted.last[:value]
    assert_equal "user@example.org", compiler.compile.first[:value]
  end

  def test_a_dump_never_carries_a_secret_value_or_names_it_in_a_label
    compiler = ChangeFlowCompiler.new([ { "fill" => { "selector" => "#p", "env" => "QA_PASSWORD" } } ],
                                      env: ENV_FIXTURE)
    refute_includes compiler.dump, "hunter2"
    refute_includes compiler.labels.join(" "), "hunter2"
    assert_includes compiler.labels.first, "QA_PASSWORD"
  end

  def test_the_function_module_carries_the_credential_because_only_the_container_may_see_it
    compiler = ChangeFlowCompiler.new([ { "fill" => { "selector" => "#p", "env" => "QA_PASSWORD" } } ],
                                      env: ENV_FIXTURE)
    assert_includes compiler.function_module, "hunter2"
  end

  # --- the compiled module ------------------------------------------------------------

  def test_the_function_module_is_one_payload_carrying_the_runtime_and_the_steps
    js = ChangeFlowCompiler.new([ { "goto" => "/" }, { "expect_visible" => "#app" } ],
                                base_url: "https://app.example.org", env: ENV_FIXTURE).function_module
    assert_includes js, "export default async ({ page }) =>"
    assert_includes js, "async function cfRunFlow(page, steps)"
    assert_includes js, "async function resolveCodeSource(codeSource)"
    assert_includes js, '"verb":"expectVisible"'
  end

  def test_compilation_is_deterministic
    steps = [ { "goto" => "/" }, { "fill" => { "selector" => "#email", "env" => "QA_EMAIL" } } ]
    first = ChangeFlowCompiler.new(steps, base_url: "https://app.example.org", env: ENV_FIXTURE).function_module
    second = ChangeFlowCompiler.new(steps, base_url: "https://app.example.org", env: ENV_FIXTURE).function_module
    assert_equal first, second
  end

  # --- golden: the browserless login payload is unchanged by the extraction --------

  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def lane(raw)
    config = ChangeConfig::LaneConfig.new("browserless", raw, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org"))
  end

  def with_env(vars)
    previous = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def js_auth_for(raw)
    with_env(ENV_FIXTURE.dup) do
      lane = lane(raw)
      JSON.parse(JSON.generate(lane.send(:js_auth, lane.send(:auth_config))))
    end
  end

  # Captured from the lane before ChangeFlowCompiler existed. The single-form
  # shorthand login: one synthesized step, both default selectors, credentials
  # read from the host env, the relative login url resolved against base_url.
  LEGACY_GOLDEN = {
    "steps" => [
      {
        "url" => "https://app.example.org/login",
        "fields" => [
          { "selector" => 'input[name="email"]', "value" => "user@example.org" },
          { "selector" => 'input[type="password"]', "value" => "hunter2" }
        ],
        "submitSelector" => 'button[type="submit"]',
        "waitForSelector" => nil,
        "timeoutMs" => 15_000
      }
    ]
  }.freeze

  # Captured from the same pre-extraction lane: the explicit two-step OTP
  # login, with the second step's code_source carried through unresolved.
  MULTI_STEP_GOLDEN = {
    "steps" => [
      {
        "url" => "https://app.example.org/login",
        "fields" => [ { "selector" => "#email", "value" => "user@example.org" } ],
        "submitSelector" => "#go",
        "waitForSelector" => "#code",
        "timeoutMs" => 5_000
      },
      {
        "url" => nil,
        "fields" => [
          { "selector" => "#otp",
            "codeSource" => { "url" => "http://mailpit:8025/latest", "pattern" => '(\d{6})',
                              "timeoutMs" => 20_000, "pollIntervalMs" => 1_000 } }
        ],
        "submitSelector" => 'button[type="submit"]',
        "waitForSelector" => nil,
        "timeoutMs" => 15_000
      }
    ]
  }.freeze

  def test_the_shorthand_login_compiles_to_the_pre_extraction_payload
    payload = js_auth_for("auth" => { "login_url" => "/login", "email_env" => "QA_EMAIL",
                                      "password_env" => "QA_PASSWORD" })
    assert_equal LEGACY_GOLDEN, payload
  end

  def test_the_multi_step_login_compiles_to_the_pre_extraction_payload
    payload = js_auth_for("auth" => { "steps" => [
      { "url" => "/login", "fields" => [ { "selector" => "#email", "env" => "QA_EMAIL" } ],
        "submit_selector" => "#go", "wait_for_selector" => "#code", "timeout_ms" => 5000 },
      { "fields" => [ { "selector" => "#otp",
                        "code_source" => { "url" => "http://mailpit:8025/latest", "pattern" => '(\d{6})' } } ] }
    ] })
    assert_equal MULTI_STEP_GOLDEN, payload
  end

  def test_the_lane_scan_module_still_carries_the_auth_runtime_it_no_longer_owns
    js = lane({}).send(:scan_module, [], nil, {})
    assert_includes js, "async function runAuthStep(session, step)"
    assert_includes js, "async function fillField(session, field, timeoutMs)"
    assert_includes js, "async function resolveCodeSource(codeSource)"
  end
end
