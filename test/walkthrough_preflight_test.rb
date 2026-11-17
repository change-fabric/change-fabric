# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_preflight"

class WalkthroughPreflightTest < Minitest::Test
  FakeSession = Struct.new(:data, :code) do
    def run_function(code)
      self.code = code
      data
    end
  end

  def persona
    { "login" => { "url" => "https://app.localhost/login", "success_selector" => "#home",
                   "steps" => [ { "op" => "type", "selector" => "#email", "env" => "PF_EMAIL" },
                                { "op" => "click", "selector" => "#go" } ] } }
  end

  def live(id, extra = {})
    { "id" => id, "screen" => { "url" => "https://app.localhost/#{id}" } }.merge(extra)
  end

  def op(name, target) = { "op" => name, "target" => target }

  def job(label, url) = { "label" => label, "url" => url, "selectors" => [] }

  def result(label, url, missing: [], error: nil) = { "label" => label, "url" => url, "missing" => missing, "error" => error }

  def board(scenes)
    { "personas" => { "member" => persona }, "scenes" => scenes }
  end

  def test_runtimes_are_installed
    assert_empty WalkthroughPreflight.asset_errors(Dir.pwd, [])
    errs = WalkthroughPreflight.asset_errors(Dir.pwd, [], runtimes: [ "/nope/walkthrough_element.js" ])
    assert_equal [ "runtime /nope/walkthrough_element.js is not installed; re-run install.rb" ], errs
  end

  def test_missing_screen_and_seed_are_reported
    Dir.mktmpdir do |root|
      scene = { "id" => "list", "screen" => { "html" => "screens/list.html" },
                "store" => { "seed" => "data/seed.json" } }
      errs = WalkthroughPreflight.asset_errors(root, [ scene ])
      assert_equal [ "list: screens/list.html is missing", "list: data/seed.json is missing" ], errs
    end
  end

  def test_live_config_needs_persona_login_and_env
    scenes = [ live("inbox", "persona" => "member"), live("admin", "persona" => "ghost") ]
    errs = WalkthroughPreflight.live_config_errors(board(scenes), scenes, env: {})
    assert_includes errs, "admin: persona \"ghost\" has no login config"
    assert_includes errs, "env PF_EMAIL is not set (a live scene needs it)"
    member = scenes.first(1)
    assert_empty WalkthroughPreflight.live_config_errors(board(member), member, env: { "PF_EMAIL" => "x" })
  end

  def test_prototype_board_needs_no_env
    scenes = [ { "id" => "list", "screen" => { "html" => "a.html" } } ]
    assert_empty WalkthroughPreflight.live_config_errors(board(scenes), scenes, env: {})
  end

  def test_selector_jobs_stop_at_the_first_state_change_and_skip_session_scenes
    scenes = [
      live("landing", "screen" => { "url" => "https://app.localhost/", "wait" => { "selector" => "main" } },
                      "interactions" => [ op("move", "#cta"), op("click", "#cta"), op("click", "#modal-ok") ]),
      live("inbox", "persona" => "member", "interactions" => [ op("scroll", "#inbox") ]),
      live("next", "session_from_scene" => "landing")
    ]
    jobs = WalkthroughPreflight.selector_jobs(board(scenes), scenes)
    assert_equal [ "persona member login", "landing" ], jobs.map { |j| j["label"] }
    assert_equal %w[#email #go], jobs[0]["selectors"]
    assert_equal %w[main #cta], jobs[1]["selectors"], "#modal-ok appears only after the click"
  end

  def test_check_selectors_reports_missing_and_unreachable
    results = [ result("landing", "https://app.localhost/", missing: [ "#cta" ]),
                result("pricing", "https://app.localhost/p", error: "net::ERR_CONNECTION_REFUSED") ]
    session = FakeSession.new({ "results" => results })
    errs = WalkthroughPreflight.check_selectors(session, board([]), [ job("landing", "https://app.localhost/") ])
    assert_equal 2, errs.size
    assert_equal "landing: selector \"#cta\" not found on https://app.localhost/", errs[0]
    assert_match(/pricing: cannot reach .*ERR_CONNECTION_REFUSED.*start the app/, errs[1])
    assert_includes session.code, "waitForSelector"
  end

  def test_check_selectors_turns_a_crash_into_a_failure
    session = Object.new
    def session.run_function(_code) = raise("socket closed")

    errs = WalkthroughPreflight.check_selectors(session, board([]), [ job("a", "https://x.test/") ])
    assert_match(/selector check could not run .*socket closed/, errs.first)
  end

  def test_no_jobs_opens_no_browser
    assert_empty WalkthroughPreflight.check_live(board([]), [])
  end
end
