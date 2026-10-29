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
    js = WalkthroughLive.capture_module(b, b["scenes"][1], plan: [ {} ], session: nil, lint: [ 0 ])
    assert_includes js, "Security.setIgnoreCertificateErrors"
    assert_includes js, 'waitUntil: "domcontentloaded"'
    assert_includes js, 'waitForSelector("main")'
    assert_includes js, "await sleep(200)"
    assert_includes js, '"tour":"on"'
    assert_operator js.index("evaluateOnNewDocument"), :<, js.index("page.goto")
    refute_includes js, "networkidle"
    b["browser"]["ignore_https_errors"] = false
    refute_includes WalkthroughLive.capture_module(b, b["scenes"][1], plan: [ {} ], session: nil, lint: []), "setIgnoreCertificateErrors"
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
        typed = WalkthroughLive.resolve_interactions(kw[:scene]["interactions"], kw[:secrets]).filter_map { |op| op["text"] }.join
        if kw[:out_dir]
          result = { "frames" => [ Base64.strict_encode64("jpg") ], "ticks" => [ 0 ], "cursor" => [ { "x" => 1, "y" => 2, "down" => false } ],
                     "lint" => [ { "rule" => "text-clipped", "target" => "#password", "detail" => "value #{typed}" } ] }
          WalkthroughLive.write_scene(result, kw[:out_dir], kw[:scene]["id"], kw[:secrets], docker: kw[:docker], work: kw[:work], board: kw[:board])
        end
        { "cookies" => [], "origins" => {}, "from" => kw[:scene]["id"] }
      end,
      docker: lambda do |argv|
        @calls[:docker] << argv
        if argv.include?("-buildconf") then [ "--enable-libass --enable-libx264", Status.new(true) ]
        elsif argv.include?("null") then [ LOUDNORM_OUT, Status.new(true) ]
        elsif argv.last.end_with?("%06d.png")
          File.binwrite(File.join(File.dirname(argv.last.sub(%r{\A/work/}, "#{@root}/")), "000001.png"), "png")
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

    render(scene: "sign-in")
    assert_equal %w[sign-in dashboard], shots, "--scene recaptures the scene and its session dependents"

    @calls.clear
    render(scene: "dashboard")
    assert_equal [ [ "sign-in", :replay, nil ], [ "dashboard", :shots, "sign-in" ] ], @calls[:capture],
                 "a cached session parent is replayed without frames"

    @calls.clear
    render(recapture: true)
    assert_equal 6, shots.size
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
