# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_compose"
require_relative "../scripts/walkthrough_assumptions"

# The compose kind: link parsing, validation, resolution from a caught link,
# and the simulated compose page.
class WalkthroughComposeTest < Minitest::Test
  MAILTO = "mailto:sales@example.test?cc=ops%40example.test&subject=Placement%20inquiry&body=Name%3A%0ANotes%3A%0A"

  def test_parses_a_mailto_link
    got = WalkthroughCompose.parse_link(MAILTO)
    assert_equal({ "channel" => "email", "to" => [ "sales@example.test" ], "cc" => [ "ops@example.test" ], "bcc" => [],
                   "subject" => "Placement inquiry", "body" => "Name:\nNotes:\n" }, got)
  end

  def test_parses_multiple_recipients_and_crlf_bodies
    got = WalkthroughCompose.parse_link("mailto:a@example.test,b@example.test?to=c@example.test&bcc=d@example.test&body=one%0D%0Atwo")
    assert_equal %w[a@example.test b@example.test c@example.test], got["to"]
    assert_equal [ "d@example.test" ], got["bcc"]
    assert_equal "one\ntwo", got["body"]
  end

  def test_parses_sms_and_tel_links
    assert_equal({ "channel" => "sms", "to" => [ "+15550100", "+15550101" ], "body" => "Hi there" },
                 WalkthroughCompose.parse_link("sms:+15550100,+15550101?body=Hi%20there"))
    assert_equal "a+b", WalkthroughCompose.parse_link("SMS:+15550100&body=a+b")["body"]
    assert_equal({ "channel" => "tel", "to" => [ "+15550100" ] }, WalkthroughCompose.parse_link("tel:+15550100"))
    assert_raises(ArgumentError) { WalkthroughCompose.parse_link("https://example.test") }
  end

  def scenes = { orders: { "form" => 1, "mail" => 2, "proto" => 3 }, realtime: [ "form" ] }

  def test_validation
    from = { "id" => "mail", "order" => 2, "kind" => "compose", "compose" => { "from_scene" => "form" } }
    assert_empty WalkthroughCompose.errors(from, scenes)
    explicit = { "order" => 2, "compose" => { "channel" => "sms", "to" => "+15550100", "body" => "hi" } }
    assert_empty WalkthroughCompose.errors(explicit, scenes)
    assert_includes WalkthroughCompose.errors({ "order" => 2 }, scenes).join, "compose is required"
    assert_includes WalkthroughCompose.errors(from.merge("order" => 1), scenes).join, "earlier scene"
    assert_includes WalkthroughCompose.errors(from.merge("order" => 4, "compose" => { "from_scene" => "proto" }), scenes).join, "live scene"
    assert_includes WalkthroughCompose.errors({ "compose" => { "from_scene" => "form", "to" => "x" }, "order" => 2 }, scenes).join, "excludes"
    sms = { "order" => 2, "compose" => { "channel" => "sms", "to" => "+1", "subject" => "x" } }
    assert_includes WalkthroughCompose.errors(sms, scenes).join, "only to and body"
    assert_includes WalkthroughCompose.errors({ "order" => 2, "compose" => { "channel" => "fax" } }, scenes).join, "compose.to is required"
  end

  def test_resolve_takes_the_last_email_or_sms_link
    scene = { "id" => "mail", "compose" => { "from_scene" => "form" } }
    links = [ WalkthroughCompose.parse_link(MAILTO), WalkthroughCompose.parse_link("tel:+15550100") ]
    assert_equal "Placement inquiry", WalkthroughCompose.resolve(scene, links: links)["subject"]
    assert_raises(ArgumentError) { WalkthroughCompose.resolve(scene, links: nil) }
    assert_raises(ArgumentError) { WalkthroughCompose.resolve(scene, links: [ links.last ]) }
    assert_equal [ "x@example.test" ], WalkthroughCompose.resolve({ "compose" => { "channel" => "email", "to" => "x@example.test" } })["to"]
  end

  def test_html_fills_the_templates_and_escapes
    page = WalkthroughCompose.html(WalkthroughCompose.parse_link(MAILTO).merge("subject" => "<b>"), "desktop")
    assert_includes page, 'id="cc" value="ops@example.test"'
    assert_includes page, "&lt;b&gt;"
    assert_includes page, "Name:\nNotes:\n</textarea>"
    refute_includes page, "{{"
    sms = WalkthroughCompose.html({ "channel" => "sms", "to" => [ "+15550100" ], "body" => "hi" }, "phone")
    assert_includes sms, 'class="phone"'
    assert_includes sms, 'class="thread"'
    assert_includes sms, 'id="send"'
  end

  def test_assumptions_note_simulated_ui
    board = { "title" => "Demo", "scenes" => [
      { "id" => "mail", "order" => 1, "kind" => "compose", "compose" => { "from_scene" => "form" } }
    ] }
    assert_includes WalkthroughAssumptions.render(board), "- mail: simulated compose UI built from the app's real link (scene form); nothing is sent"
  end
end
