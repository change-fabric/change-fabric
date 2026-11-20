# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "approval_console_preview"

# The preview renderer is a development tool, so these tests pin only what the
# transition tests and the stills rely on: every route renders with the real
# headers, lifetimes are fresh, POST answers follow ?respond=, and the
# fragment handler exists in the preview and nowhere in the page output.
class ApprovalConsolePreviewTest < Minitest::Test
  NOW = Time.utc(2026, 11, 20, 18, 0, 0)

  def preview = ApprovalConsolePreview.new(now: -> { NOW })

  def routes
    types = ApprovalConsolePreview::TYPES.flat_map { |type| ApprovalConsolePreview::STATES.map { |state| "/type/#{type}/state/#{state}" } }
    types + %w[/page/enroll /page/enroll-shown /page/register /page/notice]
  end

  def test_every_route_renders_with_the_real_response_headers
    routes.each do |route|
      status, headers, body = preview.response("GET", route)
      assert_equal 200, status, route
      nonce = headers["content-security-policy"][/script-src 'nonce-([^']+)'/, 1]
      assert_equal ConsolePages.headers(nonce), headers, route
      assert(body.scan(/<(?:script|style)\b[^>]*>/).all? { |tag| tag.include?(%(nonce="#{nonce}")) }, "#{route}: every tag carries the nonce")
    end
  end

  def test_unknown_routes_are_404
    [ "/type/mystery/state/pending", "/type/step/state/frozen", "/nope" ].each { |route| assert_equal 404, preview.response("GET", route).first, route }
    assert_equal 404, preview.response("POST", "/nope/approve").first
  end

  def test_the_lifetime_is_fresh_on_every_render
    body = preview.response("GET", "/type/step/state/pending").last
    data = JSON.parse(body[%r{<script type="application/json" id="d"[^>]*>(.*?)</script>}m, 1])
    parsed = JSON.parse(data["body"])
    assert_equal "2026-11-20T18:00:00Z", parsed["created_at"]
    assert_equal "2026-11-20T18:15:00Z", parsed["expires_at"]
  end

  def test_post_answers_follow_the_respond_query
    status, _, body = preview.response("POST", "/type/step/state/pending/approve")
    assert_equal 200, status
    assert JSON.parse(body).key?("proof")
    status, _, body = preview.response("POST", "/type/step/state/pending/approve?respond=401:totp_invalid")
    assert_equal [ 401, "totp_invalid" ], [ status, JSON.parse(body)["error"] ]
    status, _, body = preview.response("POST", "/type/step/state/pending/approve?respond=423:locked")
    assert_equal [ 423, "2026-11-20T18:10:00Z" ], [ status, JSON.parse(body)["locked_until"] ]
  end

  def test_the_fragment_handler_is_in_the_preview_only
    body = preview.response("GET", "/type/step/state/pending").last
    assert_includes body, "state=("
    direct = ConsolePages.approve("n", "{}", { "type" => "step" }, "pending", [])
    refute_includes direct, "state="
    refute_includes ConsolePages::COMMON_JS + ConsolePages::APPROVE_JS, "location.hash"
  end
end
