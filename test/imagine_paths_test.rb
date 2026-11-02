# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require_relative "../scripts/imagine_paths"

class ImaginePathsTest < Minitest::Test
  def setup
    @saved = ENV.fetch("CF_IMAGINE_ROOT", nil)
    @tmp = Dir.mktmpdir
    ENV["CF_IMAGINE_ROOT"] = File.join(@tmp, "store")
  end

  def teardown
    @saved ? ENV["CF_IMAGINE_ROOT"] = @saved : ENV.delete("CF_IMAGINE_ROOT")
    FileUtils.remove_entry(@tmp)
  end

  def repo = File.join(@tmp, "repo")

  def record(name)
    dir = File.join(repo, "docs", "creative")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "x")
  end

  def test_default_root_and_override
    assert_equal File.join(@tmp, "store"), ImaginePaths.root
    ENV.delete("CF_IMAGINE_ROOT")
    assert_equal ImaginePaths.default_root, ImaginePaths.root
    assert ImaginePaths.default_root.end_with?("/.claude/cf/imagine")
  end

  def test_resolve_keys_and_slugify
    result = ImaginePaths.resolve(area: "acme", slug: "Launch Brand!")
    assert_equal "launch-brand", result[:slug]
    assert_equal File.join(@tmp, "store", "acme", "launch-brand"), result[:dir]
    assert_equal false, result[:exists]
    %i[root root_tilde area slug dir dir_tilde exists].each { |k| assert result.key?(k), k }
  end

  def test_next_record_missing_dir
    assert_equal "0001", ImaginePaths.next_record(repo:)
  end

  def test_next_record_sequence_and_gaps
    record("0001-a.md")
    record("0002-b.md")
    assert_equal "0003", ImaginePaths.next_record(repo:)
    record("0005-c.md")
    assert_equal "0006", ImaginePaths.next_record(repo:)
  end

  def test_next_record_ignores_non_matching
    record("0002-a.md")
    record("README.md")
    record("12-short.md")
    record("0009-nope.txt")
    assert_equal "0003", ImaginePaths.next_record(repo:)
  end

  def test_duplicate_raises_and_cli_exits_1
    record("0002-a.md")
    record("0002-b.md")
    err = assert_raises(ImaginePaths::DuplicateNumber) { ImaginePaths.next_record(repo:) }
    assert_match(/0002-a\.md, 0002-b\.md/, err.message)
    status = nil
    _, stderr = capture_io do
      status = assert_raises(SystemExit) { ImaginePaths::CLI.run([ "next-record", "--repo", repo ], out: StringIO.new) }.status
    end
    assert_equal 1, status
    assert_match(/duplicate/, stderr)
  end

  def test_cli_outputs_and_unknown_verb
    record("0002-a.md")
    out = StringIO.new
    ImaginePaths::CLI.run([ "next-record", "--repo", repo ], out:)
    assert_equal({ "number" => "0003", "dir" => "docs/creative" }, JSON.parse(out.string))
    out = StringIO.new
    ImaginePaths::CLI.run([ "resolve", "--area", "a", "--slug", "S T" ], out:)
    assert_equal "s-t", JSON.parse(out.string)["slug"]
    e = assert_raises(SystemExit) { ImaginePaths::CLI.run([ "bogus" ], out: StringIO.new) }
    assert_equal 2, e.status
  end
end
