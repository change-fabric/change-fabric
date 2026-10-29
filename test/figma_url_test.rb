# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/figma_url"

class FigmaUrlTest < Minitest::Test
  def test_design_url_with_node_id
    p = FigmaUrl.parse("https://www.figma.com/design/AbCdEf123/Example-App?node-id=12-34")
    assert_equal "AbCdEf123", p.file_key
    assert_equal "12:34", p.node_id
    assert_nil p.branch_key
    assert_equal "design", p.kind
  end

  def test_file_url
    p = FigmaUrl.parse("https://figma.com/file/XyZ789/Legacy")
    assert_equal "XyZ789", p.file_key
    assert_equal "file", p.kind
  end

  def test_branch_key_wins_as_file_key
    p = FigmaUrl.parse("https://www.figma.com/design/Main123/branch/Br456/App?node-id=1-2")
    assert_equal "Br456", p.file_key
    assert_equal "Br456", p.branch_key
    assert_equal "1:2", p.node_id
  end

  def test_node_id_after_other_params
    p = FigmaUrl.parse("https://www.figma.com/design/K1/App?t=abc&node-id=5-6")
    assert_equal "5:6", p.node_id
  end

  def test_missing_node_id
    assert_nil FigmaUrl.parse("https://www.figma.com/design/K1/App").node_id
  end

  def test_non_figma_host_returns_nil
    assert_nil FigmaUrl.parse("https://example.com/design/K1/App")
    assert_nil FigmaUrl.parse(nil)
    assert_nil FigmaUrl.parse("not a url")
  end

  def test_trailing_whitespace
    p = FigmaUrl.parse("  https://www.figma.com/make/Mk9/Thing  \n")
    assert_equal "Mk9", p.file_key
    assert_equal "make", p.kind
  end

  def test_cli_prints_json
    script = File.expand_path("../scripts/figma_url.rb", __dir__)
    out = IO.popen([ "ruby", script, "https://www.figma.com/design/AbC1/App?node-id=1-2" ], &:read)
    assert_equal({ "file_key" => "AbC1", "node_id" => "1:2", "branch_key" => nil, "kind" => "design" },
                 JSON.parse(out))
  end

  def test_cli_rejects_non_figma_url
    script = File.expand_path("../scripts/figma_url.rb", __dir__)
    IO.popen([ "ruby", script, "https://example.com/x", err: File::NULL ], &:read)
    refute $?.success?
  end
end
