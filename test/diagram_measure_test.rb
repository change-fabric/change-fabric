# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../scripts/diagram_lint"

# Covers DiagramMeasure: the browserless measurer's cache, its single
# session per run, its size guard, the CLI's exit 3 when Docker is missing,
# and one real measurement when Docker is present.
class DiagramMeasureTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/diagram", __dir__)

  # Stands in for a browserless session; answers every text with a 40x10 box.
  class FakeSession
    attr_reader :calls

    def initialize = @calls = []

    def run_function(js)
      @calls << js
      ids = js.scan(/<text[^>]*?id=\\?"([^"\\]+)/).flatten
      ids.to_h { |id| [ id, { "x" => 1, "y" => 2, "w" => 40, "h" => 10 } ] }
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @session = FakeSession.new
    @starts = 0
  end

  def teardown = FileUtils.rm_rf(@dir)

  def measurer(available: true)
    browser = lambda do |&blk|
      @starts += 1
      blk.call(@session)
    end
    DiagramMeasure::Browserless.new(cache_dir: @dir, browser: browser, available: -> { available })
  end

  def doc(name = "clean_flow.svg") = DiagramSvg::Document.new(File.read(File.join(FIXTURES, name)))

  def test_miss_measures_and_hit_skips_docker
    d = doc
    first = measurer.widths(d)
    assert_equal 1, @starts
    assert_equal first, measurer(available: false).widths(d)
    assert_equal 1, @starts
    assert_equal d.texts.map(&:key).sort, first.keys.sort
  end

  def test_cache_key_mixes_in_the_pinned_image
    refute_equal Digest::SHA256.hexdigest("x"), DiagramMeasure::Browserless.key("x")
    assert_equal DiagramMeasure::Browserless.key("x"), DiagramMeasure::Browserless.key("x")
  end

  def test_prefetch_uses_one_session_for_all_misses
    m = measurer
    m.prefetch([ doc("clean_flow.svg"), doc("clean_architecture.svg") ])
    assert_equal 1, @starts
    assert_equal 2, @session.calls.size
    m.prefetch([ doc("clean_flow.svg") ])
    assert_equal 1, @starts
  end

  def test_no_screenshot_in_the_module
    refute_match(/captureScreenshot|screenshot/, measurer.js_module("<svg/>"))
  end

  def test_size_guard_refuses_oversize_bodies
    big = "<svg>#{'a' * (DiagramMeasure::Browserless::MAX_BODY_BYTES + 1)}</svg>"
    assert_raises(DiagramMeasure::TooLarge) { measurer.js_module(big) }
  end

  def test_unavailable_docker_raises
    assert_raises(DiagramMeasure::Unavailable) { measurer(available: false).widths(doc) }
  end

  def test_cli_exits_3_without_docker
    err = StringIO.new
    code = DiagramLint.main([ File.join(FIXTURES, "clean_flow.svg") ], out: StringIO.new, err: err,
                                                                       measurer: measurer(available: false))
    assert_equal 3, code
    assert_match(/--no-measure/, err.string)
  end

  def test_cli_no_measure_uses_static
    code = DiagramLint.main([ "--no-measure", File.join(FIXTURES, "clean_flow.svg") ], out: StringIO.new, err: StringIO.new)
    assert_equal 0, code
  end

  def svg_doc(body)
    DiagramSvg::Document.new(%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">#{body}</svg>))
  end

  def static_box(body) = DiagramMeasure::Static.new.widths(svg_doc(body)).values.first

  def test_static_box_follows_the_anchor
    assert_equal [ 100.0, 92.0, 24.0, 12.0 ].map { |v| v.round(6) }, static_box(%(<text x="100" y="100" font-size="10">abcd</text>)).map { |v| v.round(6) }
    assert_in_delta 88.0, static_box(%(<text x="100" y="100" font-size="10" text-anchor="middle">abcd</text>))[0]
    assert_in_delta 76.0, static_box(%(<text x="100" y="100" font-size="10" text-anchor="end">abcd</text>))[0]
  end

  def test_static_box_unions_tspan_lines
    body = %(<text x="100" y="100" font-size="10" text-anchor="middle"><tspan x="100">ab</tspan><tspan x="100" dy="12">abcdef</tspan></text>)
    x, y, w, h = static_box(body)
    assert_in_delta 82.0, x
    assert_in_delta 92.0, y
    assert_in_delta 36.0, w
    assert_in_delta 24.0, h
    assert_equal "ab\nabcdef", svg_doc(body).texts.first.content
  end

  def test_text_in_nested_group_keeps_its_node
    d = svg_doc(%(<g class="node" data-id="n1"><rect x="0" y="0" width="80" height="40"/><g><text x="4" y="20">hi</text></g></g>))
    assert_equal "n1", d.texts.first.node_id
  end

  def test_context_text_box_reads_the_full_box
    ctx = DiagramChecks::Context.new(type: "flow", widths: { "t0" => [ 1, 2, 3, 4 ] }, measured: true, palette: nil)
    box = ctx.text_box(svg_doc(%(<text x="9" y="9">x</text>)).texts.first)
    assert_equal [ 1, 2, 3, 4 ], [ box.x, box.y, box.w, box.h ]
  end

  def test_old_format_cache_entry_is_a_miss
    d = doc
    key = DiagramMeasure::Browserless.key(d.source)
    File.write(File.join(@dir, "#{key}.json"), JSON.generate(d.texts.to_h { |t| [ t.key, [ 40, 10 ] ] }))
    result = measurer.widths(d)
    assert_equal 1, @starts
    assert(result.values.all? { |v| v.size == 4 })
  end

  def test_cache_key_carries_the_version
    refute_equal Digest::SHA256.hexdigest("#{ChangeDocker::BROWSERLESS_IMAGE}\nx"), DiagramMeasure::Browserless.key("x")
  end

  def test_real_browserless_full_box_matches_static
    skip "docker not available" unless ChangeDocker.available?

    body = %(<text id="mid" x="200" y="100" font-family="sans-serif" font-size="14" text-anchor="middle">Submit order</text>) +
           %(<text id="two" x="200" y="150" font-family="sans-serif" font-size="14" text-anchor="middle"><tspan x="200">Line one</tspan><tspan x="200" dy="17">Line two</tspan></text>)
    d = svg_doc(body)
    real = DiagramMeasure::Browserless.new(cache_dir: @dir).widths(d)
    est = DiagramMeasure::Static.new.widths(d)
    %w[mid two].each do |k|
      rx, ry, rw, rh = real.fetch(k)
      ex, ey, ew, eh = est.fetch(k)
      assert_in_delta ex + (ew / 2), rx + (rw / 2), 3, "#{k} center x"
      assert_in_delta ey, ry, 6, "#{k} top"
      assert_in_delta eh, rh, 8, "#{k} height"
    end
  end

  def test_real_browserless_measures_text
    skip "docker not available" unless ChangeDocker.available?

    d = doc
    widths = DiagramMeasure::Browserless.new(cache_dir: @dir).widths(d)
    assert_equal d.texts.map(&:key).sort, widths.keys.sort
    assert(widths.values.all? { |_x, _y, w, h| w.positive? && h.positive? })
  end
end
