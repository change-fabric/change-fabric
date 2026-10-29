# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_assumptions"
require_relative "../scripts/walkthrough_message"
require_relative "../scripts/walkthrough_storyboard"

# The message kind: validation, the four views, the prototype screen writer
# with and without a project shell, and the ASSUMPTIONS line.
class WalkthroughMessageTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/walkthrough_message", __dir__)

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "screens"))
    FileUtils.cp(File.join(FIXTURES, "shell.html"), File.join(@root, "screens", "shell.html"))
    FileUtils.cp(File.join(FIXTURES, "icon.svg"), File.join(@root, "screens", "icon.svg"))
    File.write(File.join(@root, "screens", "tokens.css"), ":root { --accent: #a4532f; }")
  end

  def teardown = FileUtils.rm_rf(@root)

  def sms(view = "lock_banner", extra = {})
    { "channel" => "sms", "view" => view, "from" => "Sam Lee", "body" => "Is the 9am slot still open?", "time" => "now" }.merge(extra)
  end

  def email(view = "open", extra = {})
    { "channel" => "email", "view" => view, "from" => "Demo App", "to" => "sam@example.test", "subject" => "Your loan is confirmed",
      "body" => "Pick up Saturday at 9.\nFront desk, level 2." }.merge(extra)
  end

  def scene(spec, extra = {}) = { "id" => "ask", "order" => 1, "kind" => "message", "message" => spec }.merge(extra)

  def ctx = { orders: { "ask" => 1, "approve" => 2, "later" => 3 }, board: { "title" => "Demo App" }, root: @root }

  def errs(spec, extra = {}) = WalkthroughMessage.errors(scene(spec, extra), ctx)

  def test_validation
    assert_empty errs(sms)
    assert_empty errs(sms("thread"))
    assert_empty errs(email("inbox", "others" => [ { "from" => "Pat", "subject" => "Hi", "preview" => "x", "time" => "8:02" } ]))
    assert_empty errs(email("open", "cta" => { "label" => "View loan", "to_scene" => "approve" }, "app" => { "name" => "Demo App", "icon" => "screens/icon.svg" }))
    {
      "message.channel must be one of" => sms.merge("channel" => "fax"),
      "message.view for sms must be one of lock_banner, thread" => sms("inbox"),
      "message.from is required" => sms.merge("from" => ""),
      "message.subject is required for an email" => email.merge("subject" => nil),
      "must be the next scene" => email("open", "cta" => { "label" => "Go", "to_scene" => "later" }),
      "message.cta applies only to an open email" => email("inbox", "cta" => { "label" => "Go", "to_scene" => "approve" }),
      "message.others applies only to inbox" => sms.merge("others" => []),
      "clock and message.date apply only to lock_banner" => sms("thread", "clock" => "9:41"),
      "message.app.icon screens/none.svg does not exist" => sms.merge("app" => { "icon" => "screens/none.svg" }),
      "message has unknown keys: color" => sms.merge("color" => "red"),
      "message.shell needs a screen.html" => sms.merge("shell" => "screens/shell.html")
    }.each { |want, spec| assert(errs(spec).any? { |e| e.include?(want) }, "#{want}: #{errs(spec)}") }
    assert_includes WalkthroughMessage.errors(scene(nil), ctx).join, "message is required"
  end

  def test_views_fill_and_escape
    lock = WalkthroughMessage.view(sms("lock_banner", "from" => "Sam <Lee>", "clock" => "8:15", "date" => "Saturday, November 21"))
    assert_includes lock, 'id="banner"'
    assert_includes lock, "Sam &lt;Lee&gt;"
    assert_includes lock, "8:15"
    assert_includes WalkthroughMessage.view(sms("thread")), 'id="reply"'
    inbox = WalkthroughMessage.view(email("inbox", "others" => [ { "from" => "Pat", "subject" => "Garden swap" } ]))
    assert_includes inbox, "Garden swap"
    assert_includes inbox, "Pick up Saturday at 9."
    open = WalkthroughMessage.view(email("open", "cta" => { "label" => "View loan", "to_scene" => "approve" }), board: { "title" => "Demo App" })
    assert_includes open, 'id="cta"'
    assert_includes open, "to sam@example.test"
    refute_includes open, "{{"
    icon = WalkthroughMessage.view(sms.merge("app" => { "icon" => "screens/icon.svg" }), root: @root)
    assert_includes icon, "data:image/svg+xml;base64,"
  end

  def test_live_page_inlines_root_tokens
    File.write(File.join(@root, "tokens.css"), ":root { --accent: #123456; }")
    page = WalkthroughMessage.page(sms, "phone", root: @root)
    assert_includes page, "--accent: #123456"
    assert_includes page, 'class="cfm-page phone"'
  end

  def test_writes_prototype_screens_and_flags_stale_ones
    board = { "title" => "Demo App", "scenes" => [
      scene(sms.merge("shell" => "screens/shell.html"), "screen" => { "html" => "screens/ask.html" }),
      scene(email, "id" => "mail", "order" => 2, "screen" => { "html" => "screens/mail.html" })
    ] }
    stale = WalkthroughMessage.errors(board["scenes"][0], ctx.merge(board: board))
    assert_includes stale.join, "screens/ask.html is stale"
    assert_equal %w[screens/ask.html screens/mail.html], WalkthroughMessage.write_screens(board, @root)
    assert_empty WalkthroughMessage.errors(board["scenes"][0], ctx.merge(board: board))
    shelled = File.read(File.join(@root, "screens", "ask.html"))
    assert_includes shelled, '<div class="phone"><div data-cf-message><div class="cfm cfm-lock"'
    assert_includes shelled, "<style>/* message template"
    assert_includes File.read(File.join(@root, "screens", "mail.html")), '<link rel="stylesheet" href="tokens.css">'
  end

  def test_storyboard_routes_message_scenes
    proto = scene(sms, "screen" => { "html" => "screens/ask.html" })
    assert WalkthroughLive.realtime?(scene(sms))
    refute WalkthroughLive.realtime?(proto)
    assert WalkthroughLive.builtin?(scene(sms))
  end

  def test_assumptions_note_simulated_notifications
    board = { "title" => "Demo", "scenes" => [ scene(sms) ] }
    assert_includes WalkthroughAssumptions.render(board),
                    "- ask: simulated notification (sms lock_banner from Sam Lee); nothing is sent or received"
  end
end
