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

  # Stands in for a browserless session; answers every text with 40x10.
  class FakeSession
    attr_reader :calls

    def initialize = @calls = []

    def run_function(js)
      @calls << js
      ids = js.scan(/<text[^>]*?id=\\?"([^"\\]+)/).flatten
      ids.to_h { |id| [ id, [ 40, 10 ] ] }
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

  def test_real_browserless_measures_text
    skip "docker not available" unless ChangeDocker.available?

    d = doc
    widths = DiagramMeasure::Browserless.new(cache_dir: @dir).widths(d)
    assert_equal d.texts.map(&:key).sort, widths.keys.sort
    assert(widths.values.all? { |w, h| w.positive? && h.positive? })
  end
end
