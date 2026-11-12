# frozen_string_literal: true

require "open3"
require "minitest/autorun"
require "base64"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/image_plate"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

class ImagePlateTest < Minitest::Test
  include ImagegenHelpers
  include EnrollHelpers

  # Answers run_function with canned shots, or an overflow list, and keeps the JS.
  class FakeSession
    attr_reader :modules

    def initialize(overflow: [])
      @overflow = overflow
      @modules = []
    end

    def run_function(code)
      @modules << code
      names = JSON.parse(JSON.parse(code[/const dims = JSON\.parse\((".*?")\);/, 1])).keys
      return { "overflow" => @overflow } unless @overflow.empty?

      { "shots" => names.to_h { |n| [ n, Base64.strict_encode64("SHOT-#{n}") ] } }
    end
  end

  def fake_browser(session) = ->(&blk) { blk.call(session) }

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, ".cache")
    @repo = File.join(@dir, "repo").tap { |d| Dir.mkdir(d) }
    @outdir = File.join(@dir, "out")
    @out = StringIO.new
    enroll_home!("openai")
  end

  def teardown
    restore_home!
    FileUtils.rm_rf(@dir)
  end

  def spec_hash(sizes: nil, copy: nil)
    {
      "copy" => copy || { "headline" => "Ship release gates you can trust", "body" => "Five lanes.", "cta" => "Start free" },
      "sizes" => sizes || [
        { "name" => "desktop", "width" => 1920, "height" => 600, "zone" => { "x" => 0.05, "y" => 0.15, "w" => 0.45, "h" => 0.7 } },
        { "name" => "wide", "width" => 1200, "height" => 628, "zone" => { "x" => 0.05, "y" => 0.1, "w" => 0.5, "h" => 0.8 } }
      ],
      "focal" => { "x" => 0.7, "y" => 0.45 }
    }
  end

  MIXED = [
    { "name" => "desktop", "width" => 1920, "height" => 600, "zone" => { "x" => 0.05, "y" => 0.15, "w" => 0.45, "h" => 0.7 } },
    { "name" => "mobile", "width" => 750, "height" => 1334, "zone" => { "x" => 0.08, "y" => 0.6, "w" => 0.84, "h" => 0.32 } }
  ].freeze

  def write_spec(hash, pretty: false)
    File.join(@dir, "spec-#{rand(1 << 30)}.json").tap do |p|
      File.write(p, pretty ? JSON.pretty_generate(hash) : JSON.generate(hash))
    end
  end

  def cli(spec_path, session: FakeSession.new, http: ImagegenHelpers::FakeHttp.new, available: -> { true }, **opts)
    ImagePlate::Cli.run({ prompt: "a calm ocean", spec: spec_path, cache: @cache, out: @outdir }.merge(opts),
                        out: @out, http: http, browser: fake_browser(session), available: available, repo: @repo)
  end

  def assert_spec_error(hash, pattern)
    assert_equal 2, cli(write_spec(hash))
    assert_match pattern, @out.string
  end

  def test_missing_headline_exits_2
    assert_spec_error(spec_hash(copy: { "body" => "x" }), /copy\.headline/)
  end

  def test_zone_out_of_range_exits_2
    sizes = [ { "name" => "a", "width" => 100, "height" => 50, "zone" => { "x" => 0.6, "y" => 0, "w" => 0.5, "h" => 1 } } ]
    assert_spec_error(spec_hash(sizes: sizes), /zone is out of range/)
  end

  def test_duplicate_name_exits_2
    s = { "name" => "a", "width" => 100, "height" => 50, "zone" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } }
    assert_spec_error(spec_hash(sizes: [ s, s ]), /a is not unique/)
  end

  def test_size_name_that_escapes_out_dir_exits_2
    [ "../existing", "a/b", "/abs", "..", ".", "a\\b", "x y" ].each do |bad|
      @out = StringIO.new
      sizes = [ { "name" => bad, "width" => 100, "height" => 50, "zone" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } } ]
      assert_spec_error(spec_hash(sizes: sizes), /plain filename/)
    end
  end

  # Every name SAFE_NAME admits must survive the trip through the generated JS
  # module: object-literal specials (__proto__), inherited Object.prototype
  # members, and filesystem-adjacent shapes all come back as their own shot.
  JS_SPECIAL_NAMES = %w[__proto__ constructor toString valueOf hasOwnProperty __defineGetter__ prototype length 0 1e3 .hidden a.b -x].freeze

  def test_generated_module_keeps_every_safe_name_as_its_own_shot
    skip "node not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)

    JS_SPECIAL_NAMES.each do |name|
      @out = StringIO.new
      session = FakeSession.new
      sizes = [ { "name" => name, "width" => 100, "height" => 50, "zone" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } } ]
      assert_equal 0, cli(write_spec(spec_hash(sizes: sizes)), session: session), "#{name}: #{@out.string}"
      assert_equal [ name ], run_module_in_node(session.modules.first), "#{name}: dropped by the generated module"
    end
  end

  def run_module_in_node(code)
    mod = File.join(@dir, "mod-#{rand(1 << 30)}.mjs").tap { |p| File.write(p, code) }
    runner = <<~JS
      const { default: fn } = await import(#{JSON.generate("file://#{mod}")});
      const el = { screenshot: async () => "U0hPVA==" };
      const page = { setViewport: async () => {}, setContent: async () => {}, evaluate: async () => false, $: async () => el };
      const out = await fn({ page });
      process.stdout.write(JSON.stringify(Object.keys(out.data.shots)));
    JS
    stdout, status = Open3.capture2("node", "--input-type=module", "-e", runner)
    assert status.success?, "node failed running the generated module"
    JSON.parse(stdout)
  end

  def test_malformed_json_exits_2
    path = File.join(@dir, "bad.json").tap { |p| File.write(p, "{nope") }
    assert_equal 2, cli(path)
  end

  def test_missing_spec_exits_2
    assert_equal 2, cli(nil)
    assert_match "heavy text needs --spec copy.json", @out.string
  end

  def test_all_landscape_is_one_paid_call
    http = ImagegenHelpers::FakeHttp.new
    assert_equal 0, cli(write_spec(spec_hash), http: http)
    assert_equal 1, http.requests.size
    assert_match(/1536x1024/, http.requests.first.body)
    assert_equal "SHOT-desktop", File.binread(File.join(@outdir, "desktop.png"))
    assert_equal "SHOT-wide", File.binread(File.join(@outdir, "wide.png"))
  end

  def test_unenrolled_uncached_plate_exits_4_with_one_enroll_line
    unenroll!("openai")
    http = ImagegenHelpers::FakeHttp.new
    assert_equal 4, with_enrolled { cli(write_spec(spec_hash), http: http) }
    assert_one_enroll_line(@out.string, "openai")
    assert_empty http.requests
  end

  def test_unenrolled_cached_plate_exits_0_without_asking
    spec = write_spec(spec_hash)
    assert_equal 0, cli(spec)
    unenroll!("openai")
    @out = StringIO.new
    http = ImagegenHelpers::FakeHttp.new
    assert_equal 0, with_enrolled { cli(spec, http: http) }, @out.string
    assert_empty enroll_lines(@out.string)
    assert_empty http.requests
  end

  def test_mixed_sizes_two_calls_second_carries_ref
    http = ImagegenHelpers::FakeHttp.new
    assert_equal 0, cli(write_spec(spec_hash(sizes: MIXED)), http: http)
    assert_equal 2, http.requests.size
    first, second = http.requests
    assert_equal "/v1/images/generations", first.path
    assert_equal "/v1/images/edits", second.path
    assert_includes second.body, "1024x1536"
    assert_match(/multipart/, second["Content-Type"])
  end

  def test_estimate_counts_families
    assert_equal 0, cli(write_spec(spec_hash(sizes: MIXED)), estimate_only: true)
    assert_match "2 plate(s), $0.10 to spend", @out.string
  end

  # The second plate's key includes the first plate as a reference, so the
  # estimate must resolve it rather than assume the second is uncached.
  def test_estimate_after_copy_change_is_free_for_every_size_mix
    [ spec_hash, spec_hash(sizes: MIXED) ].each do |hash|
      assert_equal 0, cli(write_spec(hash))
      changed = hash.merge("copy" => hash["copy"].merge("headline" => "Different words"))
      @out = StringIO.new
      http = ImagegenHelpers::FakeHttp.new
      assert_equal 0, cli(write_spec(changed), http: http, max_usd: 0)
      assert_match "$0.00 to spend", @out.string
      assert_empty http.requests
    end
  end

  def test_ceiling_exits_1_before_any_call
    http = ImagegenHelpers::FakeHttp.new
    assert_equal 1, cli(write_spec(spec_hash(sizes: MIXED)), http: http, max_usd: 0.05)
    assert_empty http.requests
  end

  def run_for(hash, version: ImagePlate::IMAGE_PLATE_VERSION)
    ImagePlate::Run.new(spec: ImagePlate::Spec.parse(JSON.generate(hash)), prompt: "p", cache: @cache, repo: @repo, version: version)
  end

  def test_key_stable_across_reformatting
    compact = ImagePlate::Spec.load(write_spec(spec_hash))
    pretty = ImagePlate::Spec.load(write_spec(spec_hash, pretty: true))
    assert_equal compact.digest, pretty.digest
    assert_equal run_for(spec_hash).composite_key, run_for(JSON.parse(JSON.pretty_generate(spec_hash))).composite_key
  end

  def test_key_changes_with_copy_and_version
    base = run_for(spec_hash).composite_key
    refute_equal base, run_for(spec_hash(copy: { "headline" => "Other" })).composite_key
    refute_equal base, run_for(spec_hash, version: ImagePlate::IMAGE_PLATE_VERSION + 1).composite_key
  end

  def test_key_changes_with_any_inlined_style_dependency
    File.write(File.join(@repo, "tokens.css"), %(@import "type.css";\n:root{--ink:#111;--accent:#06c;--bg:#fff}\n))
    File.write(File.join(@repo, "type.css"), %(@font-face{font-family:D;src:url("d.woff2")}\n:root{--font-display:D}\n))
    File.binwrite(File.join(@repo, "d.woff2"), "font-v1")
    edits = {
      "tokens.css" => ->(f) { File.write(f, File.read(f).sub("#111", "#222")) },
      "type.css" => ->(f) { File.write(f, File.read(f).sub("--font-display:D", "--font-display:serif")) },
      "d.woff2" => ->(f) { File.binwrite(f, "font-v2") }
    }
    edits.each do |name, edit|
      before = run_for(spec_hash).composite_key
      edit.call(File.join(@repo, name))
      refute_equal before, run_for(spec_hash).composite_key, "editing #{name} left the key unchanged"
    end
  end

  def test_cache_hit_skips_calls_and_render
    path = write_spec(spec_hash)
    assert_equal 0, cli(path)
    http = ImagegenHelpers::FakeHttp.new
    session = FakeSession.new
    assert_equal 0, cli(path, http: http, session: session, available: -> { false })
    assert_empty http.requests
    assert_empty session.modules
  end

  def test_overflow_exits_1_naming_size
    assert_equal 1, cli(write_spec(spec_hash), session: FakeSession.new(overflow: [ "wide" ]))
    assert_match "copy overflows zone for size wide", @out.string
  end

  def test_docker_unavailable_exits_3
    assert_equal 3, cli(write_spec(spec_hash), available: -> { false })
  end

  def test_browser_raising_exits_3
    raising = ->(&_blk) { raise IOError, "docker gone" }
    code = ImagePlate::Cli.run({ prompt: "p", spec: write_spec(spec_hash), cache: @cache, out: @outdir }, out: @out,
                               http: ImagegenHelpers::FakeHttp.new, browser: raising, available: -> { true }, repo: @repo)
    assert_equal 3, code
  end

  def test_fallback_colors_without_tokens_file
    session = FakeSession.new
    assert_equal 0, cli(write_spec(spec_hash), session: session)
    js = session.modules.first
    assert_includes js, "--cf-ink:#{ImagePlate::FALLBACK_COLORS['--ink']}"
    assert_includes js, "--cf-accent:#{ImagePlate::FALLBACK_COLORS['--accent']}"
    assert_includes js, "object-position:70.0% 45.0%"
  end

  def test_overlay_colors_follow_imported_token_declarations
    variants = {
      "top level" => { "tokens.css" => ":root{--bg:#fff;--ink:#111;--accent:#006600}" },
      "quoted import" => { "tokens.css" => %(@import "pal.css";), "pal.css" => ":root{--bg:#fff;--ink:#111;--accent:#006600}" },
      "url import" => { "tokens.css" => %(@import url(pal.css);), "pal.css" => ":root{--bg:#fff;--ink:#111;--accent:#006600}" },
      "nested import" => { "tokens.css" => %(@import "a.css";), "a.css" => %(@import "pal.css";),
                           "pal.css" => ":root{--bg:#fff;--ink:#111;--accent:#006600}" },
      "import beside local" => { "tokens.css" => %(@import "pal.css";\n:root{--ink:#111}), "pal.css" => ":root{--bg:#fff;--accent:#006600}" }
    }
    variants.each do |name, files|
      Dir.glob(File.join(@repo, "*.css")).each { |f| File.delete(f) }
      @cache = File.join(@dir, "cache-#{name.tr(" ", "-")}")
      files.each { |f, body| File.write(File.join(@repo, f), body) }
      session = FakeSession.new
      assert_equal 0, cli(write_spec(spec_hash), session: session), name
      assert_includes session.modules.first, "--cf-accent:#006600", "#{name}: imported accent not honored"
    end
  end

  def test_plate_prompt_holds_zone_clear
    prompt = run_for(spec_hash).plate_prompt(:landscape)
    assert_includes prompt, "No text, letters, logos, or watermarks"
    assert_match(/keep the \d+% to \d+% across, \d+% to \d+% down region calm/, prompt)
  end
end
