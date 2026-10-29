# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "yaml"
require_relative "../scripts/prototype_flats"

# record-figma and routes-snippet: pure file work, no Figma or browser.
class PrototypeFlatsFigmaTest < Minitest::Test
  F = PrototypeFlatsFigma
  URL = "https://www.figma.com/design/AbCdEf123/Example-App"

  def with_flats
    Dir.mktmpdir do |dir|
      path = File.join(dir, "flats.json")
      File.write(path, JSON.generate("flats" => [ { "screen" => "x" } ]))
      yield path
    end
  end

  def test_record_writes_figma_block_and_keeps_flats
    with_flats do |path|
      F.record(flats_path: path, url: URL, frames: { "checkout-empty" => "12-34" })
      data = JSON.parse(File.read(path))
      assert_equal({ "url" => URL, "file_key" => "AbCdEf123", "frames" => { "checkout-empty" => "12:34" } }, data["figma"])
      assert_equal [ { "screen" => "x" } ], data["flats"]
    end
  end

  def test_record_merges_frames_across_runs
    with_flats do |path|
      F.record(flats_path: path, url: URL, frames: { "a" => "1:1" })
      F.record(flats_path: path, url: URL, frames: { "b" => "2:2" })
      assert_equal({ "a" => "1:1", "b" => "2:2" }, JSON.parse(File.read(path)).dig("figma", "frames"))
    end
  end

  def test_record_uses_branch_key
    with_flats do |path|
      block = F.record(flats_path: path, url: "https://www.figma.com/design/AbC/branch/BrK/App", frames: { "a" => "1:1" })
      assert_equal "BrK", block["file_key"]
    end
  end

  def test_record_rejects_bad_input
    with_flats do |path|
      assert_raises(ArgumentError) { F.record(flats_path: path, url: "https://example.com/x", frames: { "a" => "1:1" }) }
      assert_raises(ArgumentError) { F.record(flats_path: path, url: "https://www.figma.com/board/AbC/B", frames: { "a" => "1:1" }) }
      assert_raises(ArgumentError) { F.record(flats_path: path, url: URL, frames: {}) }
    end
  end

  def test_parse_pairs
    assert_equal({ "a" => "1:2" }, F.parse_pairs([ "a=1:2" ], "--node"))
    assert_raises(ArgumentError) { F.parse_pairs([ "a" ], "--node") }
  end

  def test_routes_snippet_yaml
    with_flats do |path|
      F.record(flats_path: path, url: URL, frames: { "checkout-empty" => "12:34", "home" => "5:6" })
      yaml = F.routes_snippet(flats_path: path, routes: { "home" => "/" })
      parsed = YAML.safe_load(yaml)
      assert_equal "/TODO-checkout-empty", parsed["routes"][0]["path"]
      assert_equal({ "file_key" => "AbCdEf123", "node_id" => "12:34", "viewport" => "desktop" }, parsed["routes"][0]["figma"])
      assert_equal "/", parsed["routes"][1]["path"]
    end
  end

  def test_routes_snippet_needs_figma_block
    with_flats { |path| assert_raises(ArgumentError) { F.routes_snippet(flats_path: path) } }
  end

  def test_cli_dispatch
    with_flats do |path|
      F.cli([ "record-figma", "--flats", path, "--url", URL, "--node", "a=1:1" ])
      assert_includes F.cli([ "routes-snippet", "--flats", path, "--route", "a=/a" ]), "path: /a"
    end
  end
end
