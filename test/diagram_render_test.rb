# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "stringio"
require "tmpdir"
require_relative "../scripts/diagram_render"

# Covers DiagramRender: one browserless session for both schemes, the PNG
# files it writes, and its exit codes for usage and missing Docker.
class DiagramRenderTest < Minitest::Test
  CLEAN = File.expand_path("fixtures/diagram/clean_flow.svg", __dir__)

  # Answers run_function with a fake shot per scheme.
  class FakeSession
    attr_reader :calls

    def initialize = @calls = []

    def run_function(js)
      @calls << js
      { "light" => Base64.strict_encode64("L"), "dark" => Base64.strict_encode64("D") }
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @session = FakeSession.new
    @starts = 0
  end

  def teardown = FileUtils.rm_rf(@dir)

  def renderer(available: true)
    browser = lambda do |&blk|
      @starts += 1
      blk.call(@session)
    end
    DiagramRender.new(browser: browser, available: -> { available })
  end

  def run_main(argv, available: true, out: StringIO.new, err: StringIO.new)
    DiagramRender.main(argv, out: out, err: err, renderer: renderer(available: available))
  end

  def test_renders_both_schemes_in_one_session
    shots = renderer.render(File.read(CLEAN))
    assert_equal({ "light" => "L", "dark" => "D" }, shots)
    assert_equal 1, @starts
    assert_includes @session.calls.first, "prefers-color-scheme"
  end

  def test_main_writes_light_and_dark_pngs
    out = StringIO.new
    prefix = File.join(@dir, "flow")
    code = run_main([ "--out-prefix", prefix, CLEAN ], out: out)
    assert_equal 0, code
    assert_equal "L", File.binread("#{prefix}-light.png")
    assert_equal "D", File.binread("#{prefix}-dark.png")
    assert_equal [ "#{prefix}-light.png", "#{prefix}-dark.png" ], out.string.lines.map(&:chomp)
  end

  def test_missing_docker_exits_3
    err = StringIO.new
    code = run_main([ "--out-prefix", File.join(@dir, "x"), CLEAN ], available: false, err: err)
    assert_equal 3, code
    assert_equal 0, @starts
    assert_match(/Docker/, err.string)
  end

  def test_unreadable_file_exits_2
    code = run_main([ File.join(@dir, "nope.svg") ])
    assert_equal 2, code
  end

  def test_bad_scale_exits_2
    code = run_main([ "--scale", "9", CLEAN ])
    assert_equal 2, code
  end
end
