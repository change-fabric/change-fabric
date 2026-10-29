# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/walkthrough_render"

# Live scenes (screen.url): schema validation, cache keying, browser option
# passthrough, session sourcing in the render, and env-value masking.
class WalkthroughLiveTest < Minitest::Test
  Status = Struct.new(:ok) do
    def success? = ok
  end
  SECRET = "s3cret-#{SecureRandom.hex(6)}".freeze
  LOUDNORM_OUT = "{\n \"input_i\" : \"-20.0\", \"input_tp\" : \"-2.0\", \"input_lra\" : \"5.0\",\n" \
                 " \"input_thresh\" : \"-30.0\", \"target_offset\" : \"0.1\"\n}\n"

  def setup
    @root = Dir.mktmpdir
    @old_env = ENV.to_h.slice("CF_SECRETS_ENV", "APP_PASSWORD", "APP_EMAIL")
    ENV["CF_SECRETS_ENV"] = File.join(@root, "no-such.env")
    ENV["APP_PASSWORD"] = SECRET
    ENV["APP_EMAIL"] = "member@example.test"
    @calls = Hash.new { |h, k| h[k] = [] }
  end

  def teardown
    @old_env.each { |k, v| ENV[k] = v }
    %w[APP_PASSWORD APP_EMAIL].each { |k| ENV.delete(k) unless @old_env.key?(k) }
    FileUtils.rm_rf(@root)
  end

  def persona(url = "https://app.localhost/login")
    { "login" => { "url" => url, "success_selector" => "#dashboard",
                   "steps" => [ { "type" => "fill", "selector" => "#email", "env" => "APP_EMAIL" },
                                { "type" => "fill", "selector" => "#password", "env" => "APP_PASSWORD" },
                                { "type" => "click", "selector" => "button[type=submit]" },
                                { "type" => "wait", "selector" => "#dashboard" } ] } }
  end

  def live(id, order, extra = {})
    { "id" => id, "order" => order, "title" => id, "screen" => { "url" => "https://app.localhost/#{id}" },
      "narration" => { "text" => "Scene #{id} speaks.", "measured_ms" => 0 },
      "assumptions" => [ { "id" => "A-0#{order}", "text" => "x" } ],
      "wait" => { "until" => "domcontentloaded", "selector" => "main", "settle_ms" => 200 },
      "timing" => { "min_ms" => 1000, "pad_ms" => 200 } }.merge(extra)
  end

  def board(scenes = nil)
    { "schema_version" => 1, "slug" => "demo", "title" => "Demo", "fps" => 30,
      "viewport" => { "w" => 640, "h" => 360, "dpr" => 1 },
      "voice" => { "voice_id" => "v1", "model" => "eleven_multilingual_v2", "output_format" => "mp3_44100_128" },
      "music" => nil,
      "browser" => { "add_hosts" => [ "app.localhost:172.17.0.1" ], "network" => "app-net", "ignore_https_errors" => true },
      "personas" => { "member" => persona, "admin" => persona },
      "scenes" => scenes || [
        live("sign-in", 1, "interactions" => [
          { "t_ms" => 0, "op" => "type", "target" => "#email", "text" => "member@example.test" },
          { "t_ms" => 800, "op" => "type", "target" => "#password", "env" => "APP_PASSWORD" },
          { "t_ms" => 1600, "op" => "click", "target" => "button[type=submit]" }
        ]),
        live("dashboard", 2, "session_from_scene" => "sign-in",
                             "storage" => { "clear" => [ "sessionStorage" ], "set" => { "localStorage" => { "tour" => "on" } } }),
        live("inbox", 3, "persona" => "member", "interactions" => [ { "t_ms" => 0, "op" => "scroll", "target" => "#inbox" } ]),
        live("reports", 4, "persona" => "member"),
        live("admin", 5, "persona" => "admin"),
        live("landing", 6, "persona" => nil)
      ] }
  end

  def errors_for(b) = WalkthroughStoryboard.validate(b)

  MAILTO = "mailto:sales@example.test?cc=ops%40example.test&subject=Placement%20inquiry&body=Name%3A%0ANotes%3A%0A"

  def compose_scene(id, order, spec, extra = {})
    { "id" => id, "order" => order, "title" => id, "kind" => "compose", "compose" => spec,
      "narration" => { "text" => "Scene #{id} speaks.", "measured_ms" => 0 },
      "assumptions" => [ { "id" => "A-0#{order}", "text" => "x" } ], "timing" => { "min_ms" => 1000, "pad_ms" => 200 } }.merge(extra)
  end

  def device_board
    board([
      live("contact", 1, "persona" => "member", "devices" => %w[desktop phone], "layout" => "side_by_side",
                         "interactions" => { "desktop" => [ { "t_ms" => 0, "op" => "click", "target" => "#email-us" } ],
                                             "phone" => [ { "t_ms" => 0, "op" => "click", "target" => "#menu" } ] }),
      live("mobile", 2, "session_from_scene" => "contact", "devices" => [ "phone" ]),
      compose_scene("mail", 3, { "from_scene" => "contact" },
                    "interactions" => [ { "t_ms" => 0, "op" => "type", "target" => "#body", "text" => "Hi" },
                                        { "t_ms" => 600, "op" => "click", "target" => "#send" } ]),
      compose_scene("text", 4, { "channel" => "sms", "to" => "+15550100", "body" => "On my way" }, "devices" => [ "phone" ])
    ]).merge("phone" => { "w" => 390, "h" => 844, "dpr" => 2 })
  end

  def test_devices_layouts_and_compose_validate
    assert_empty errors_for(device_board)
    b = device_board
    b["scenes"][0]["interactions"]["tablet"] = []
    b["scenes"][1]["device"] = "phone"
    b["scenes"][2]["compose"] = { "from_scene" => "text" }
    b["scenes"][3]["layout"] = "side_by_side"
    errs = errors_for(b)
    [ "interactions name devices the scene does not film: tablet", "device is replaced by devices",
      "compose.from_scene text must be an earlier", "side_by_side needs" ].each { |want| assert(errs.any? { |e| e.include?(want) }, "#{want}: #{errs}") }
    proto = live("proto", 1, "screen" => { "html" => "screens/a.html" }, "devices" => [ "phone" ])
    assert(errors_for(board([ proto ])).any? { |e| e.include?("devices needs a screen.url") })
  end

  def test_after_line_types_at_a_template_line
    b = device_board
    mail = b["scenes"][2]
    mail["interactions"][0]["after_line"] = "Name:"
    assert_empty errors_for(b)
    step = jobs(b, mail).first["plan"].find { |st| st["type"] }
    assert_equal "Name:", step["type"]["after_line"]
    assert_includes WalkthroughLive.capture_module(b, mail, jobs: [], session: nil), "step.type.after_line"
    mail["interactions"][1]["after_line"] = "x"
    assert(errors_for(b).any? { |e| e.include?("after_line apply only to a type op") })
    proto = live("proto", 1, "screen" => { "html" => "screens/a.html" },
                             "interactions" => [ { "t_ms" => 0, "op" => "type", "target" => "#b", "text" => "x", "after_line" => "A" } ])
    assert(errors_for(board([ proto ])).any? { |e| e.include?("after_line needs a live or compose scene") })
  end

  def test_side_by_side_runs_both_devices_in_parallel
    b = device_board
    js = WalkthroughLive.capture_module(b, b["scenes"][0], jobs: jobs(b, b["scenes"][0]), session: nil)
    assert_includes js, "Promise.all"
    assert_includes js, '"name":"phone"'
    assert_includes js, '"mobile":true'
    assert_includes js, "touchscreen.tap"
    assert_includes js, "isMobile: !!dev.mobile"
    phone = jobs(b, b["scenes"][0]).last
    assert_equal "#menu", phone["plan"].find { |st| st["click"] }["click"]
    assert_equal "phone side_by_side", phone["group"]
    mail = jobs(b, b["scenes"][3]).first
    assert_nil mail["url"]
  end

  def test_compose_keys_on_its_source_scene
    b = device_board
    base = key(b, "mail")
    b["scenes"][0]["screen"]["url"] = "https://app.localhost/other"
    refute_equal base, key(b, "mail")
    c = device_board
    c["scenes"][3]["compose"]["body"] = "Late"
    refute_equal key(device_board, "text"), key(c, "text")
  end

  def test_render_fills_compose_from_the_caught_link
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(device_board))
    render
    assert_equal %w[contact mobile mail text], shots
    mail, text = @calls[:compose]
    assert_equal [ "email", [ "ops@example.test" ], "Placement inquiry", "Name:\nNotes:\n" ], mail.values_at("channel", "cc", "subject", "body")
    assert_equal({ "channel" => "sms", "to" => [ "+15550100" ], "body" => "On my way" }, text)
    links = JSON.parse(File.read(Dir[File.join(@root, ".cache", "frames", "*", "links.json")].find { |f| File.read(f).include?("mailto") }))
    assert_equal MAILTO, links.first["href"]
  end

  # -- schema ---------------------------------------------------------------

  def test_good_live_board_validates
    assert_empty errors_for(board)
  end

  def test_login_is_never_required
    assert_empty errors_for(board([ live("landing", 1) ]).merge("personas" => nil))
  end

  def test_fill_step_without_env_is_rejected
    b = board
    b["personas"]["member"]["login"]["steps"][1].delete("env")
    assert(errors_for(b).any? { |e| e.include?("fill needs env") })
  end

  def test_literal_credential_is_rejected
    b = board
    b["personas"]["member"]["login"]["steps"][1]["password"] = "hunter2"
    b["personas"]["admin"]["login"]["steps"][0]["value"] = "a@example.test"
    errs = errors_for(b)
    assert(errs.any? { |e| e.include?("member") && e.include?("password is a literal credential") })
    assert(errs.any? { |e| e.include?("admin") && e.include?("value is a literal credential") })
  end

  def test_screen_with_both_url_and_html_is_rejected
    b = board
    b["scenes"][0]["screen"]["html"] = "screens/a.html"
    assert_includes errors_for(b), 'scene "sign-in": screen takes exactly one of html or url'
  end

  def test_type_takes_exactly_one_of_text_or_env
    b = board
    b["scenes"][0]["interactions"][1]["text"] = "x"
    assert(errors_for(b).any? { |e| e.include?("exactly one of text or env") })
  end

  def test_live_scene_rules
    b = board
    b["scenes"][1]["session_from_scene"] = "admin"
    b["scenes"][2]["persona"] = "nobody"
    b["scenes"][3]["wait"] = { "until" => "networkidle0" }
    b["scenes"][4]["store"] = { "seed" => "data/seed.json" }
    b["scenes"][5]["storage"] = { "set" => { "cookies" => {} } }
    b["browser"]["network"] = "none"
    errs = errors_for(b)
    [ "session_from_scene admin must be an earlier scene", "persona \"nobody\" is not in the top-level personas",
      "wait.until must be one of domcontentloaded, load", "a live scene has no store", "storage.set maps",
      "browser.network must not be none" ].each { |want| assert(errs.any? { |e| e.include?(want) }, want) }
  end

  def test_live_only_fields_on_a_prototype_scene_are_rejected
    proto = live("proto", 1, "screen" => { "html" => "screens/a.html" }, "persona" => "member",
                             "interactions" => [ { "t_ms" => 0, "op" => "type", "target" => "#p", "env" => "APP_PASSWORD" } ])
    errs = errors_for(board([ proto ]))
    assert(errs.any? { |e| e.include?("persona needs a screen.url") })
    assert(errs.any? { |e| e.include?("scroll and env typing need a screen.url") })
  end

  # -- keys -----------------------------------------------------------------

  def key(b, id, memo = {}) = WalkthroughLive.prepare(b, b["scenes"].find { |s| s["id"] == id }, @root, memo)[:key]

  def test_cache_key_covers_url_persona_steps_viewport_and_parent
    base = key(board, "inbox")
    changes = {
      url: ->(b) { b["scenes"][2]["screen"]["url"] = "https://app.localhost/other" },
      persona: ->(b) { b["scenes"][2]["persona"] = "admin" },
      steps: ->(b) { b["scenes"][2]["interactions"][0]["target"] = "#archive" },
      viewport: ->(b) { b["viewport"]["w"] = 1280 },
      login: ->(b) { b["personas"]["member"]["login"]["success_selector"] = "#home" }
    }
    changes.each do |name, change|
      b = board
      change.call(b)
      refute_equal base, key(b, "inbox"), "#{name} re-keys the scene"
    end
    b = board
    b["scenes"][0]["screen"]["url"] = "https://app.localhost/sign-in-v2"
    refute_equal key(board, "dashboard"), key(b, "dashboard"), "a session parent re-keys its dependents"
  end

  def test_cache_key_ignores_env_values
    before = key(board, "sign-in")
    ENV["APP_PASSWORD"] = "another"
    assert_equal before, key(board, "sign-in")
    refute_includes JSON.generate(WalkthroughStoryboard.recompute_keys(board, @root)), SECRET
  end

  # -- passthrough ----------------------------------------------------------

  def test_add_hosts_reach_the_browserless_container
    argv = ChangeDocker.browserless_command("cf-change-bl-x", "app-net", 1234, "tok", [ "app.localhost:10.0.0.5" ])
    assert_includes argv.each_cons(2).to_a, [ "--network", "app-net" ]
    assert_includes argv.each_cons(2).to_a, [ "--add-host", "app.localhost:10.0.0.5" ]
  end

  def test_capture_module_waits_seeds_and_ignores_https_errors
    b = board
    js = WalkthroughLive.capture_module(b, b["scenes"][1], jobs: jobs(b, b["scenes"][1]), session: nil)
    assert_includes js, "Security.setIgnoreCertificateErrors"
    assert_includes js, 'waitUntil: "domcontentloaded"'
    assert_includes js, 'waitForSelector("main")'
    assert_includes js, "await sleep(200)"
    assert_includes js, '"tour":"on"'
    assert_operator js.index("evaluateOnNewDocument"), :<, js.index("page.goto")
    refute_includes js, "networkidle"
    assert_includes js, "if (!to) throw new Error(`click target not found: ${step.click}`);"
    refute_includes js, "if (to) pos = to;"
    b["browser"]["ignore_https_errors"] = false
    refute_includes WalkthroughLive.capture_module(b, b["scenes"][1], jobs: [], session: nil), "setIgnoreCertificateErrors"
  end

  def jobs(b, scene)
    secrets = WalkthroughLive::Secrets.new([])
    WalkthroughDevice.specs(b, scene).map { |spec| WalkthroughLive.job(b, scene, spec, secrets, compose: nil, shots: true) }
  end

  # -- render ---------------------------------------------------------------

  def providers
    { tts: lambda do |**kw|
      key = ElevenLabs.audio_key(**kw.slice(:text, :voice_id, :model, :output_format, :settings))
      WalkthroughCache.fetch(kw[:cache_root], :audio, key, "mp3") do |tmp|
        File.binwrite(tmp, "mp3")
        chars = kw[:text].chars
        File.write(WalkthroughCache.path(kw[:cache_root], :audio, key, "alignment.json"),
                   JSON.generate("characters" => chars, "character_start_times_seconds" => chars.each_index.map { |i| i * 0.05 },
                                 "character_end_times_seconds" => chars.each_index.map { |i| (i + 1) * 0.05 }))
      end
      { measured_ms: kw[:text].length * 50 }
    end,
      browser: ->(&_blk) { flunk "a live board opens no offline prototype browser" },
      live_browser: lambda do |opts, &blk|
        @calls[:live_browser] << opts
        blk.call(:session)
      end,
      live_login: lambda do |**kw|
        @calls[:login] << (kw[:persona].equal?(kw[:board]["personas"]["admin"]) ? "admin" : "member")
        { "cookies" => [ { "name" => "sid", "value" => "v" } ], "origins" => {} }
      end,
      live_capture: lambda do |**kw|
        @calls[:capture] << [ kw[:scene]["id"], kw[:out_dir] ? :shots : :replay, kw[:browser_session] && kw[:browser_session]["from"] ]
        @calls[:compose] << kw[:compose] if kw[:compose]
        typed = WalkthroughLive.resolve_interactions(WalkthroughLive.all_interactions(kw[:scene]), kw[:secrets]).filter_map { |op| op["text"] }.join
        if kw[:out_dir]
          result = { "frames" => [ Base64.strict_encode64("jpg#{@takes = @takes.to_i + 1}") ], "ticks" => [ 0 ], "cursor" => [ { "x" => 1, "y" => 2, "down" => false } ],
                     "lint" => [ { "rule" => "text-clipped", "target" => "#password", "detail" => "value #{typed}" } ],
                     "links" => kw[:scene]["id"] == "contact" ? [ MAILTO ] : [] }
          WalkthroughLive::SceneWriter.new(board: kw[:board], scene: kw[:scene], secrets: kw[:secrets], docker: kw[:docker], work: kw[:work])
                                      .write(WalkthroughDevice.devices(kw[:scene]).map { |d| result.merge("name" => d) }, kw[:out_dir])
        end
        { "cookies" => [], "origins" => {}, "from" => kw[:scene]["id"] }
      end,
      docker: lambda do |argv|
        @calls[:docker] << argv
        if argv.include?("-buildconf") then [ "--enable-libass --enable-libx264", Status.new(true) ]
        elsif argv.include?("null") then [ LOUDNORM_OUT, Status.new(true) ]
        elsif argv.last.end_with?("%06d.png")
          File.binwrite(File.join(File.dirname(argv.last.sub(%r{\A/work/}, "#{@root}/")), "000001.png"), "png#{@takes}")
          [ "", Status.new(true) ]
        else
          File.binwrite(argv.last.sub(%r{\A/work/}, "#{@root}/"), "mp4")
          [ "", Status.new(true) ]
        end
      end }
  end

  def render(**opts)
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(board)) unless File.file?(File.join(@root, "storyboard.json"))
    @log = StringIO.new
    WalkthroughRender::Run.new(@root, **{ providers: providers, out: @log, gates: { roast: false, allow_ux: true } }.merge(opts)).call
  end

  def pass2s = Array(@calls[:docker]).select { |a| a.any? { |x| x.to_s.end_with?("walkthrough.mp4") } }

  def shots = @calls[:capture].select { |c| c[1] == :shots }.map(&:first)

  def test_render_sources_sessions_and_caches_live_scenes
    render
    assert_equal [ board["browser"] ], @calls[:live_browser], "browser options reach the live container"
    assert_equal %w[member admin], @calls[:login], "one login per persona, reused across its scenes"
    assert_equal %w[sign-in dashboard inbox reports admin landing], shots
    assert_equal "sign-in", @calls[:capture].find { |c| c[0] == "dashboard" }[2], "session_from_scene hands the end session on"
    assert_nil @calls[:capture].find { |c| c[0] == "landing" }[2], "persona null starts logged out"
    refute(@calls[:docker].any? { |a| a.include?("%06d.jpg") && !a.each_cons(2).include?([ "--network", "none" ]) })

    @calls.clear
    render
    assert_empty @calls[:capture], "live scenes are cached by key"
    assert_empty pass2s, "an unchanged capture reuses the cached render"

    render(scene: "sign-in")
    assert_equal %w[sign-in dashboard], shots, "--scene recaptures the scene and its session dependents"
    assert_equal 1, pass2s.size, "new captured frames reassemble despite an unchanged manifest"

    @calls.clear
    render(scene: "dashboard")
    assert_equal [ [ "sign-in", :replay, nil ], [ "dashboard", :shots, "sign-in" ] ], @calls[:capture],
                 "a cached session parent is replayed without frames"

    @calls.clear
    render(recapture: true)
    assert_equal 6, shots.size
    assert_equal 1, pass2s.size, "--recapture reassembles despite an unchanged manifest"
  end

  def test_secret_never_reaches_a_written_artifact
    render
    files = Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
    assert(files.any? { |f| f.end_with?("ux-lint.json") })
    files.each { |f| refute_includes File.binread(f), SECRET.b, "#{f.delete_prefix(@root)} holds the secret" }
    refute_includes @log.string, SECRET
    lint = JSON.parse(File.read(Dir[File.join(@root, ".cache", "frames", "*", "ux-lint.json")].min))
    refute_nil lint
  end

  def test_logs_and_errors_are_masked
    run = WalkthroughRender::Run.new(@root, board: board, providers: providers, out: (log = StringIO.new))
    run.say("typed #{SECRET}")
    assert_equal "typed [masked]\n", log.string
    secrets = WalkthroughLive::Secrets.new(%w[APP_PASSWORD])
    err = assert_raises(WalkthroughLive::CaptureError) { WalkthroughLive.guard(secrets) { raise "page said #{SECRET}" } }
    refute_includes err.message, SECRET
    assert_raises(WalkthroughLive::MissingEnvError) { WalkthroughLive::Secrets.new(%w[UNSET_VAR_X]).fetch("UNSET_VAR_X") }
  end
end

class WalkthroughLiveRetryTest < Minitest::Test
  # Every variant: live login, live capture job, and mixed jobs never replay;
  # only all-built-in jobs keep the batch retry.
  def test_live_work_is_never_replayed
    assert_equal 0, WalkthroughLive.retries_for([ { 'html' => nil } ])
    assert_equal 0, WalkthroughLive.retries_for([ { 'html' => '<p>' }, { 'html' => nil } ])
    assert_equal PrototypeCapture::BATCH_RETRIES, WalkthroughLive.retries_for([ { 'html' => '<p>' } ])
  end

  def test_dropped_live_call_surfaces_instead_of_retrying
    calls = 0
    session = Object.new
    session.define_singleton_method(:run_function) { |_c| calls += 1; raise EOFError }
    session.define_singleton_method(:alive?) { true }
    assert_raises(EOFError) { PrototypeCapture.run_with_retry(session, 'x', retries: WalkthroughLive.retries_for([ { 'html' => nil } ])) }
    assert_equal 1, calls
  end
end
