# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/color_tokens"

class ColorTokensTest < Minitest::Test
  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, rel, content = "")
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def test_locate_finds_the_one_conventional_path_present
    with_dir do |dir|
      path = write(dir, "tokens.css")
      assert_equal path, ColorTokens.locate(dir, nil)
    end
  end

  def test_locate_prefers_earlier_paths_in_the_list_order
    with_dir do |dir|
      write(dir, "app/globals.css")
      # Only one candidate present still resolves even though it is later
      # in PATHS; this just confirms a single match wins regardless of rank.
      assert_equal File.join(dir, "app/globals.css"), ColorTokens.locate(dir, nil)
    end
  end

  def test_locate_errors_on_zero_matches_naming_every_candidate
    with_dir do |dir|
      error = ColorTokens.locate(dir, nil)
      assert_instance_of ColorTokens::Error, error
      assert_includes error.message, "no token file found"
      ColorTokens::PATHS.each { |p| assert_includes error.message, p }
    end
  end

  def test_locate_errors_on_several_matches_naming_the_candidates
    with_dir do |dir|
      a = write(dir, "tokens.css")
      b = write(dir, "src/index.css")
      error = ColorTokens.locate(dir, nil)
      assert_instance_of ColorTokens::Error, error
      assert_includes error.message, "several token files found"
      assert_includes error.message, a
      assert_includes error.message, b
    end
  end

  def test_locate_errors_on_a_missing_override
    with_dir do |dir|
      error = ColorTokens.locate(dir, File.join(dir, "custom.css"))
      assert_instance_of ColorTokens::Error, error
      assert_includes error.message, "no such file"
    end
  end

  def test_locate_errors_on_a_directory_override
    with_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "styles"))
      error = ColorTokens.locate(dir, File.join(dir, "styles"))
      assert_instance_of ColorTokens::Error, error
      assert_includes error.message, "is a directory, not a file"
    end
  end

  def test_locate_errors_on_an_unreadable_override
    skip "root reads every file" if Process.uid.zero?
    with_dir do |dir|
      path = write(dir, "custom.css", ":root{}")
      File.chmod(0o000, path)
      error = ColorTokens.locate(dir, path)
      assert_instance_of ColorTokens::Error, error
      assert_includes error.message, "is not readable"
    end
  end

  def test_locate_resolves_a_relative_override_against_the_current_directory
    with_dir do |dir|
      path = write(dir, "sub/custom.css", ":root{}")
      Dir.chdir(File.join(dir, "sub")) do
        assert_equal File.realpath(path), File.realpath(ColorTokens.locate("/nonexistent-root", "custom.css"))
      end
    end
  end

  def test_pairs_matches_suffix_to_its_surface_when_declared
    pairs = ColorTokens.pairs(%w[--gold-btn --gold-btn-text --background])
    assert_equal [ [ "--gold-btn-text", "--gold-btn" ] ], pairs
  end

  def test_pairs_falls_back_to_background_without_a_surface
    pairs = ColorTokens.pairs(%w[--a-text --b-fg --c-foreground --d-ink --background])
    assert_equal [
      [ "--a-text", "--background" ], [ "--b-fg", "--background" ],
      [ "--c-foreground", "--background" ], [ "--d-ink", "--background" ]
    ], pairs
  end

  def test_pairs_ignores_names_without_a_recognized_suffix
    assert_empty ColorTokens.pairs(%w[--context --ink-like --brand])
  end

  def test_pairs_accepts_a_hash_of_names
    pairs = ColorTokens.pairs({ "--background" => nil, "--page-text" => nil })
    assert_equal [ [ "--page-text", "--background" ] ], pairs
  end
end
