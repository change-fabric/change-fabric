# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "securerandom"
require "tmpdir"
require_relative "../scripts/walkthrough_live"

# Drives the live capture against a tiny login fixture served from a node
# container on an ephemeral docker network, with no external network. The
# browser reaches it by a made-up hostname mapped through browser.add_hosts.
class WalkthroughLiveBrowserTest < Minitest::Test
  SERVER = File.expand_path("fixtures/walkthrough_live/server.js", __dir__)
  PASSWORD = "fixture-pw-#{SecureRandom.hex(6)}".freeze
  EMAIL = "member@example.test"
  HOST = "app.example.test"

  def test_login_session_reuse_storage_seed_and_capture
    skip "docker not available" unless ChangeDocker.available?

    with_fixture do |network, ip|
      opts = { "network" => network, "add_hosts" => [ "#{HOST}:#{ip}" ] }
      ChangeDocker.with_browserless(network: opts["network"], add_hosts: opts["add_hosts"]) do |session|
        exercise(session, board(opts))
      end
    end
  end

  private

  def exercise(session, board)
    secrets = WalkthroughLive::Secrets.new(WalkthroughLive.env_names(board), env: { "FIXTURE_PASSWORD" => PASSWORD, "FIXTURE_EMAIL" => EMAIL })
    login = WalkthroughLive.login(session: session, board: board, persona: board["personas"]["member"], secrets: secrets)
    assert(login["cookies"].any? { |c| c["name"] == "sid" }, "persona login yields the session cookie")

    seeded = scene_by(board, "seeded")
    after = WalkthroughLive.capture(session: session, board: board, scene: seeded, out_dir: nil, secrets: secrets,
                                    browser_session: login, shots: false)
    assert after["url"].end_with?("/app"), "the persona session reaches the gated page"
    origin = after["origins"]["http://#{HOST}:8080"]
    assert_equal EMAIL, origin["localStorage"]["member"], "storage from the login is restored"
    assert_equal "yes", origin["localStorage"]["seeded"], "the scene storage seed applies before navigation"

    reused = WalkthroughLive.capture(session: session, board: board, scene: scene_by(board, "reused"), out_dir: nil,
                                     secrets: secrets, browser_session: after, shots: false)
    assert reused["url"].end_with?("/app"), "a later scene reuses the earlier session"
    refute reused["origins"]["http://#{HOST}:8080"]["sessionStorage"].key?("tour_seen"), "storage.clear runs before load"

    out = WalkthroughLive.capture(session: session, board: board, scene: scene_by(board, "logged-out"), out_dir: nil,
                                  secrets: secrets, browser_session: nil, shots: false)
    assert out["url"].end_with?("/login"), "no persona means a fresh logged-out session"

    filmed_capture(session, board, secrets)
    devices_capture(session, board, secrets, login)
  end

  # A desktop login session carries into a phone scene; a side-by-side scene
  # films both devices and catches the mailto link; a compose scene types and
  # sends on the simulated page.
  def devices_capture(session, board, secrets, login)
    Dir.mktmpdir do |work|
      phone_dir = File.join(work, ".cache", "frames", "p")
      ended = WalkthroughLive.capture(session: session, board: board, scene: scene_by(board, "phone-app"), out_dir: phone_dir,
                                      secrets: secrets, browser_session: login, work: work)
      assert ended["url"].end_with?("/app"), "the desktop login session is logged in on the phone"
      assert_includes ended["ua"], "Mobile", "the phone scene runs under a mobile user agent"
      assert File.file?(File.join(phone_dir, "taps.json")), "a phone scene writes its tap track"
      assert_equal "\x89PNG".b, File.binread(Dir[File.join(phone_dir, "*.png")].min, 4)

      both_dir = File.join(work, ".cache", "frames", "b")
      WalkthroughLive.capture(session: session, board: board, scene: scene_by(board, "both"), out_dir: both_dir,
                              secrets: secrets, browser_session: login, work: work)
      link = JSON.parse(File.read(File.join(both_dir, "links.json"))).first
      assert_equal [ "email", [ "sales@example.test" ], [ "ops@example.test" ], "Placement inquiry", "Name:\nNotes:\n" ],
                   link.values_at("channel", "to", "cc", "subject", "body")

      mail = scene_by(board, "mail")
      mail_dir = File.join(work, ".cache", "frames", "m")
      WalkthroughLive.capture(session: session, board: board, scene: mail, out_dir: mail_dir, secrets: secrets, work: work,
                              compose: WalkthroughCompose.resolve(mail, links: [ link ]))
      assert_equal 15, Dir[File.join(mail_dir, "*.png")].size
    end
  end

  def filmed_capture(session, board, secrets)
    Dir.mktmpdir do |work|
      out_dir = File.join(work, ".cache", "frames", "k")
      ended = WalkthroughLive.capture(session: session, board: board, scene: scene_by(board, "sign-in"), out_dir: out_dir,
                                      secrets: secrets, work: work)
      assert ended["url"].end_with?("/app"), "the filmed login lands on the gated page"
      pngs = Dir[File.join(out_dir, "*.png")]
      assert_equal 15, pngs.size
      assert_equal "\x89PNG".b, File.binread(pngs.min, 4)
      Dir.glob(File.join(work, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.each do |file|
        refute_includes File.binread(file), PASSWORD.b, "#{File.basename(file)} must not hold the typed secret"
      end
    end
  end

  def scene_by(board, id) = board["scenes"].find { |s| s["id"] == id }

  def live_scene(id, path, extra = {})
    { "id" => id, "order" => 1, "screen" => { "url" => "http://#{HOST}:8080#{path}" },
      "wait" => { "until" => "domcontentloaded", "settle_ms" => 100 },
      "timing" => { "min_ms" => 1500, "pad_ms" => 0 } }.merge(extra)
  end

  def board(opts)
    { "fps" => 10, "viewport" => { "w" => 640, "h" => 400, "dpr" => 1 }, "phone" => { "w" => 360, "h" => 640, "dpr" => 1 }, "browser" => opts,
      "personas" => { "member" => { "login" => {
        "url" => "http://#{HOST}:8080/login", "success_selector" => "#welcome",
        "steps" => [ { "type" => "fill", "selector" => "#email", "env" => "FIXTURE_EMAIL" },
                     { "type" => "fill", "selector" => "#password", "env" => "FIXTURE_PASSWORD" },
                     { "type" => "click", "selector" => "#sign-in" } ]
      } } },
      "scenes" => [
        live_scene("seeded", "/app", "persona" => "member",
                                     "storage" => { "set" => { "localStorage" => { "seeded" => "yes" }, "sessionStorage" => { "tour_seen" => "1" } } }),
        live_scene("reused", "/app", "storage" => { "clear" => [ "tour_seen" ] }),
        live_scene("logged-out", "/app"),
        live_scene("sign-in", "/login", "interactions" => [
          { "t_ms" => 0, "op" => "type", "target" => "#email", "text" => EMAIL, "cps" => 60 },
          { "t_ms" => 500, "op" => "type", "target" => "#password", "env" => "FIXTURE_PASSWORD", "cps" => 60 },
          { "t_ms" => 1000, "op" => "click", "target" => "#sign-in" }
        ]),
        live_scene("phone-app", "/app", "devices" => [ "phone" ], "interactions" => [ { "t_ms" => 300, "op" => "click", "target" => "#welcome" } ]),
        live_scene("both", "/app", "devices" => %w[desktop phone], "layout" => "side_by_side",
                                   "interactions" => { "desktop" => [ { "t_ms" => 300, "op" => "click", "target" => "#contact" } ] }),
        { "id" => "mail", "order" => 2, "kind" => "compose", "compose" => { "from_scene" => "both" },
          "timing" => { "min_ms" => 1500, "pad_ms" => 0 },
          "interactions" => [ { "t_ms" => 0, "op" => "type", "target" => "#body", "text" => "Hi", "cps" => 60 },
                              { "t_ms" => 800, "op" => "click", "target" => "#send" } ] }
      ] }
  end

  def with_fixture
    ChangeDocker.with_network(nil) do |net|
      name = "cf-change-fx-#{SecureRandom.hex(4)}"
      _out, ok = Open3.capture2e("docker", "run", "-d", "--rm", "--name", name, "--network", net.name,
                                 "-e", "FIXTURE_PASSWORD=#{PASSWORD}", *ChangeDocker.mount_arg(SERVER, { target: "/srv/server.js", readonly: true }),
                                 ChangeDocker::NODE_IMAGE, "node", "/srv/server.js")
      assert ok.success?, "fixture server starts"
      begin
        ip, = Open3.capture2("docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", name)
        wait_ready(name)
        yield net.name, ip.strip
      ensure
        Open3.capture2e("docker", "rm", "-f", name)
      end
    end
  end

  def wait_ready(name)
    probe = "require('http').get('http://127.0.0.1:8080/login',()=>process.exit(0)).on('error',()=>process.exit(1))"
    30.times do
      return if system("docker", "exec", name, "node", "-e", probe, out: File::NULL, err: File::NULL)

      sleep 0.5
    end
    flunk "fixture server never answered"
  end
end
