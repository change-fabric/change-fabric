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
  # Baseline, extended, progressive and lossless start-of-frame markers.
  JPEG_SOF = (0xC0..0xC3)

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
    inset_capture(session, board, secrets)
    inset_isolation(session, board, secrets)
    devices_capture(session, board, secrets, login)
  end

  # The inset is drawn from a hi-res element still taken at at_ms; the same
  # runs without the still fall back to the upscaled 1x crop with a warning.
  # The hi-res inset carries more edge energy (crisper text) than the upscale.
  def inset_capture(session, board, secrets)
    scene = scene_by(board, "inset")
    jobs = inset_jobs(board, scene, secrets)
    runs = PrototypeCapture.run_with_retry(session, WalkthroughLive.capture_module(board, scene, jobs: jobs, session: nil))["devices"]
    assert_kind_of String, runs.first["insetHi"], "the capture returns a hi-res element still: #{runs.first['insetError'].inspect}"
    # A leaked clip frame would put hi-res pixels in the upscale path too.
    assert_equal [ [ 640, 400 ] ], runs.first["ticks"].uniq.map { |t| jpeg_size(runs.first["frames"][t]) }.uniq, "the still stays out of the recording"
    Dir.mktmpdir do |work|
      sharp = {}
      metas = {}
      { "hires" => runs, "upscale" => runs.map { |r| r.except("insetHi") } }.each do |name, rs|
        out_dir = File.join(work, ".cache", "frames", name)
        _o, err = capture_io { WalkthroughLive::SceneWriter.new(board: board, scene: scene, secrets: secrets, docker: nil, work: work).write(rs, out_dir) }
        meta = JSON.parse(File.read(File.join(out_dir, "inset.json")))
        assert_equal name == "hires", meta["hires"], "#{name} inset: #{err}"
        assert_equal name == "upscale", err.include?("hi-res inset capture failed"), err
        sharp[name] = hard_edges(work, out_dir, meta)
        metas[name] = meta.slice("hires", "region", "start", "stop")
      end
      assert_operator sharp["hires"], :>, sharp["upscale"] * 2, "hi-res inset is crisper: #{sharp.inspect}; still #{png_size(runs.first['insetHi']).inspect} px for box #{runs.first['inset'].inspect}; insets #{metas.inspect}; frames #{runs.first['frames'].size}, ticks #{runs.first['ticks'].size}"
    end
  end

  # A medium region at scale 2.5: the hi-res still must not leak into the
  # recording. Every raw frame after at_ms matches the first frame (the
  # page is static), and the composite inset is not blank. The leak is a
  # race (the clip shot's compositor frame reaching the screencast last),
  # so the capture runs several times and every run's frames keep the
  # viewport size.
  def inset_isolation(session, board, secrets)
    scene = scene_by(board, "inset-medium")
    jobs = inset_jobs(board, scene, secrets)
    run = nil
    4.times do |n|
      run = PrototypeCapture.run_with_retry(session, WalkthroughLive.capture_module(board, scene, jobs: jobs, session: nil))["devices"].first
      assert_kind_of String, run["insetHi"], "the capture returns a hi-res element still: #{run['insetError'].inspect}"
      sizes = run["ticks"].uniq.map { |t| jpeg_size(run["frames"][t]) }
      assert_equal [ [ 640, 400 ] ], sizes.uniq, "run #{n}: every recorded frame is the viewport, not the clip still"
    end
    Dir.mktmpdir do |work|
      assert_frames_match_page(work, run, jobs.first["inset"]["frame"])
      out_dir = File.join(work, ".cache", "frames", "medium")
      WalkthroughLive::SceneWriter.new(board: board, scene: scene, secrets: secrets, docker: nil, work: work).write([ run ], out_dir)
      meta = JSON.parse(File.read(File.join(out_dir, "inset.json")))
      assert meta["hires"], "the medium inset is drawn from the hi-res still: #{run['insetError'].inspect}"
      assert_operator hard_edges(work, out_dir, meta), :>, 20, "the medium inset carries the form, not a blank crop"
    end
  end

  # Every frame from at_ms on matches the first frame (the page is static).
  def assert_frames_match_page(work, run, from)
    first = gray(work, run["frames"][run["ticks"].first])
    run["ticks"].drop(from).uniq.each do |t|
      px = gray(work, run["frames"][t])
      assert_equal first.size, px.size, "frame #{t} keeps the viewport size"
      diff = first.zip(px).sum { |a, b| (a - b).abs } / first.size.to_f
      assert_operator diff, :<, 2.0, "frame #{t} after at_ms shows the page, not a zoomed still (mean diff #{diff.round(1)})"
    end
  end

  def inset_jobs(board, scene, secrets)
    WalkthroughDevice.specs(board, scene).map do |d|
      WalkthroughLive.job(board, scene, d, secrets, compose: nil, shots: true).merge("inset" => WalkthroughInset.job(scene, WalkthroughLive.fps_for(board)))
    end
  end

  # A base64 PNG's [width, height] from its IHDR chunk.
  def png_size(data) = data.unpack1("m").byteslice(16, 8).unpack("NN")

  # A base64 JPEG's [width, height] from its first SOF marker.
  def jpeg_size(data)
    bytes = data.unpack1("m").b
    i = 2
    while i < bytes.size
      marker, len = bytes.byteslice(i + 1, 3).unpack("Cn")
      return bytes.byteslice(i + 5, 4).unpack("nn").reverse if JPEG_SOF.cover?(marker)

      i += 2 + len
    end
    flunk "no JPEG frame header"
  end

  # One base64 JPEG frame as 8-bit gray pixels, decoded offline in FFmpeg.
  def gray(work, data)
    path = File.join(work, "f-#{SecureRandom.hex(4)}.jpg")
    File.binwrite(path, data.unpack1("m"))
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { work => "/work" }, workdir: "/work",
                                    args: [ "-v", "error", "-i", "/work/#{File.basename(path)}", "-vf", "format=gray", "-f", "rawvideo", "-" ])
    out, = Open3.capture2(*argv, binmode: true)
    out.bytes
  end

  # Hard horizontal edges (a step over 96 gray levels between neighbours)
  # inside the inset on its middle frame: an upscale smears each edge over
  # several pixels, so it has far fewer.
  def hard_edges(work, out_dir, meta)
    r = meta["region"]
    frame = format("%06d.png", ((meta["start"] + meta["stop"]) / 2) + 1)
    file = File.join(out_dir, frame).delete_prefix("#{work}/")
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, mounts: { work => "/work" }, workdir: "/work",
                                    args: [ "-v", "error", "-i", "/work/#{file}", "-vf", "crop=#{r['w'] - 8}:#{r['h'] - 8}:#{r['x'] + 4}:#{r['y'] + 4},format=gray",
                                            "-f", "rawvideo", "-" ])
    out, = Open3.capture2(*argv, binmode: true)
    px = out.bytes
    w = r["w"] - 8
    diffs = px.each_slice(w).flat_map { |row| row.each_cons(2).map { |a, b| (a - b).abs } }
    diffs.count { |d| d > 96 }
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

      mail = compose_run(session, board, secrets, work, "mail", WalkthroughCompose.resolve(scene_by(board, "mail"), links: [ link ]))
      assert_equal %w[desktop phone], mail.map { |r| r["name"] }, "a side-by-side compose films the window and the phone"
      mail.each do |run|
        assert_equal "Name: Sam Lee\nNotes:\n", run["composed"]["body"], "after_line types at the end of that line"
        assert_equal [ "Sent", "Message sent" ], run["composed"].values_at("send", "status")
      end
      text = compose_run(session, board, secrets, work, "text", WalkthroughCompose.resolve(scene_by(board, "text")))
      assert_equal [ "phone" ], text.map { |r| r["name"] }
      assert_equal [ [ "On my way, 5 min" ], "Delivered" ], text.first["composed"].values_at("bubbles", "status")
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

  # Runs a compose scene's capture and writes its frames, returning every
  # device's run so the end state of the page can be checked.
  def compose_run(session, board, secrets, work, id, spec)
    scene = scene_by(board, id)
    jobs = WalkthroughDevice.specs(board, scene).map { |d| WalkthroughLive.job(board, scene, d, secrets, compose: spec, shots: true) }
    runs = PrototypeCapture.run_with_retry(session, WalkthroughLive.capture_module(board, scene, jobs: jobs, session: nil))["devices"]
    out_dir = File.join(work, ".cache", "frames", id)
    WalkthroughLive::SceneWriter.new(board: board, scene: scene, secrets: secrets, docker: nil, work: work).write(runs, out_dir)
    assert_equal 15, Dir[File.join(out_dir, "*.png")].size
    runs
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
        live_scene("inset", "/login", "inset" => { "selector" => "#sign-in", "at_ms" => 300, "duration_ms" => 1000, "scale" => 4 }),
        live_scene("inset-medium", "/login", "inset" => { "selector" => "#login", "at_ms" => 300, "duration_ms" => 1000, "scale" => 2.5 }),
        live_scene("phone-app", "/app", "devices" => [ "phone" ], "interactions" => [ { "t_ms" => 300, "op" => "click", "target" => "#welcome" } ]),
        live_scene("both", "/app", "devices" => %w[desktop phone], "layout" => "side_by_side",
                                   "interactions" => { "desktop" => [ { "t_ms" => 300, "op" => "click", "target" => "#contact" } ] }),
        { "id" => "mail", "order" => 2, "kind" => "compose", "compose" => { "from_scene" => "both" },
          "devices" => %w[desktop phone], "layout" => "side_by_side", "timing" => { "min_ms" => 1500, "pad_ms" => 0 },
          "interactions" => [ { "t_ms" => 0, "op" => "type", "target" => "#body", "after_line" => "Name:", "text" => " Sam Lee", "cps" => 60 },
                              { "t_ms" => 1000, "op" => "click", "target" => "#send" } ] },
        { "id" => "text", "order" => 3, "kind" => "compose", "devices" => [ "phone" ],
          "compose" => { "channel" => "sms", "to" => "+15550100", "body" => "On my way" }, "timing" => { "min_ms" => 1500, "pad_ms" => 0 },
          "interactions" => [ { "t_ms" => 0, "op" => "type", "target" => "#body", "text" => ", 5 min", "cps" => 60 },
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
