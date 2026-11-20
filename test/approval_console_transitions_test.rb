# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "timeout"
require_relative "../scripts/change_docker"

# Real page-script behaviour for the state-transition table in the
# approval-console-design plan. The preview renderer serves the real page; the
# browserless-cf container loads it with the passkey and the approve POST
# stubbed from outside the page (approval_console_transitions.mjs). Skips when
# Docker is unavailable, like the other browserless tests.
#
# The preview runs on the host here and the container reaches it through the
# host alias; the same file runs in a container for manual use (see the header
# of approval_console_preview.rb).
class ApprovalConsoleTransitionsTest < Minitest::Test
  PREVIEW = File.expand_path("approval_console_preview.rb", __dir__)
  SCRIPT = File.expand_path("approval_console_transitions.mjs", __dir__)

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def self.start_preview
    stdin, out, thread = Open3.popen2e("ruby", PREVIEW, "--port", "0", "--bind", "0.0.0.0", "--public-host", ChangeDocker::HOST_ALIAS)
    stdin.close
    url = Timeout.timeout(20) { out.gets.to_s[/PREVIEW_URL=(\S+)/, 1] }
    raise "preview did not start" unless url

    [ url, thread ]
  end

  def self.results
    @results ||= begin
      url, thread = start_preview
      begin
        code = "globalThis.PREVIEW_URL = #{url.to_json};\n#{File.read(SCRIPT)}"
        ChangeDocker.with_browserless(network: nil) { |session| session.run_function(code, launch_args: [ "--unsafely-treat-insecure-origin-as-secure=#{url}" ], timeout_ms: 180_000) }
      ensure
        Process.kill("TERM", thread.pid)
        thread.join
      end
    end
  end

  def scenario(name)
    shot = self.class.results.fetch(name)
    refute shot.key?("error"), "#{name}: #{shot['error']}"
    shot
  end

  def assert_retryable(shot, text, code_kept:)
    assert shot["result_hidden"], "the result block stays hidden"
    assert_equal text, shot["msg"]
    assert shot["form"], "the form stays"
    assert shot["away"], "the not-approving line stays while the request can still be approved"
    assert_equal code_kept ? "482913" : "", shot["totp_value"]
    assert_equal !code_kept, shot["go_disabled"], "Approve is enabled only when the code is kept"
  end

  def assert_terminal(shot, kind, big, sub)
    refute shot["result_hidden"]
    assert_equal [ kind, big, sub ], shot.values_at("result_kind", "result_big", "result_sub")
    refute shot["form"], "the form is removed"
    refute shot["away"], "the not-approving line is removed"
    refute shot["has_bar"], "the mobile bar padding is released"
    assert_match(/\AMerge PR #612 into main at 32def92 \(12 files\)\z/, shot["what_changes"], "the what-changes line stays")
  end

  def test_pending_waits_for_six_digits_then_enables_and_focuses_approve
    short = scenario("code_incomplete")
    assert_equal "12345", short["totp_value"]
    assert short["go_disabled"]
    assert short["has_bar"]
    full = scenario("code_complete")
    assert_equal "124567", full["totp_value"], "non-digits are stripped"
    refute full["go_disabled"]
    assert full["go_focused"], "Approve takes focus at six digits"
  end

  def test_the_countdown_reads_the_signed_expiry
    assert_match(/\AExpires in about \d+ min \(at .+ local\)\z/, scenario("countdown")["countdown"])
  end

  def test_waiting_for_the_passkey_keeps_the_code_and_disables_approve
    shot = scenario("waiting")
    assert_equal "Waiting for your passkey", shot["msg"]
    assert shot["go_disabled"]
    assert_equal "482913", shot["totp_value"]
  end

  def test_the_post_carries_the_assertion_and_the_code
    call = scenario("wrong_code")["calls"].first
    assert_match(%r{/type/carve-out/state/pending/approve\z}, call["url"])
    body = JSON.parse(call["body"])
    assert_equal "482913", body["totp"]
    assert_equal %w[authenticator_data client_data_json credential_id signature totp], body.keys.sort
  end

  def test_a_wrong_code_clears_the_code_and_disables_approve
    assert_retryable scenario("wrong_code"), "That code did not match. Wait for the next code and try again.", code_kept: false
  end

  def test_a_replayed_code_keeps_the_page_and_asks_for_a_fresh_code
    assert_retryable scenario("replayed_code"), "That code was already used. Wait for the next code and try again.", code_kept: false
  end

  def test_a_refused_passkey_keeps_the_code
    assert_retryable scenario("assertion_failure"), "The passkey was not accepted. Try again, or use the terminal fallback.", code_kept: true
  end

  def test_a_lock_disables_the_form_and_shows_the_time
    shot = scenario("lock")
    assert_match(/\AToo many failed tries\. Locked until .+\.\z/, shot["msg"])
    assert shot["form"]
    assert shot["totp_disabled"]
    assert shot["go_disabled"]
  end

  def test_busy_and_other_refusals_keep_the_code_for_a_retry
    assert_retryable scenario("busy"), "The console is busy. Try again in a moment.", code_kept: true
    assert_retryable scenario("other_refusal"), "Refused (500): boom", code_kept: true
  end

  def test_a_cancelled_passkey_keeps_the_code
    assert_retryable scenario("passkey_cancelled"), "Passkey cancelled. Tap Approve to try again.", code_kept: true
  end

  def test_expiry_by_the_server_and_by_the_client_clock_ends_the_page
    server = scenario("expiry_server")
    assert_terminal server, "info", "Expired", server["result_sub"]
    assert_match(/\AThis request expired at .+\. Ask the agent for a new one\.\z/, server["result_sub"])
    client = scenario("expiry_client")
    assert_terminal client, "info", "Expired", client["result_sub"]
    assert_empty client["calls"], "no request was made"
  end

  def test_the_client_waits_sixty_seconds_past_expiry_before_ending_the_page
    shot = scenario("expiring_now")
    assert_equal "Expiring now", shot["countdown"]
    assert shot["form"]
    assert shot["result_hidden"]
  end

  def test_success_removes_the_form_and_confirms
    assert_terminal scenario("success"), "ok", "Approved", "The approval is recorded. You can close this page."
  end

  def test_not_pending_means_approved_elsewhere
    assert_terminal scenario("approved_elsewhere"), "info", "Approved elsewhere", "This request was already approved elsewhere. Nothing more to do."
  end

  def test_a_browser_without_passkeys_gets_a_disabled_form
    shot = scenario("passkey_unsupported")
    assert_equal "This browser cannot use passkeys. Open the link in Safari or use the terminal fallback.", shot["msg"]
    assert shot["totp_disabled"]
    assert shot["go_disabled"]
  end
end
