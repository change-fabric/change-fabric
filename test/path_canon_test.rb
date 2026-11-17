# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/path_canon"

# PathCanon answers containment after symlinks, for paths that may not exist.
class PathCanonTest < Minitest::Test
  def setup
    @tmp = File.realpath(Dir.mktmpdir)
    @root = File.join(@tmp, "root")
    @outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p([ @root, @outside ])
    File.write(File.join(@outside, "secret"), "x")
  end

  def teardown
    FileUtils.chmod_R(0o755, @tmp)
    FileUtils.remove_entry(@tmp)
  end

  def test_symlinked_root_is_canonicalized
    link = File.join(@tmp, "link-root")
    File.symlink(@root, link)
    File.write(File.join(@root, "a"), "")
    assert PathCanon.within?(File.join(link, "a"), @root)
    assert PathCanon.within?(File.join(@root, "a"), link)
    assert_equal "a", PathCanon.relative(File.join(link, "a"), link)
  end

  def test_in_repo_symlink_pointing_out_is_outside
    File.symlink(File.join(@outside, "secret"), File.join(@root, "leak"))
    refute PathCanon.within?(File.join(@root, "leak"), @root)
  end

  def test_symlinked_parent_directory_pointing_out_is_outside
    File.symlink(@outside, File.join(@root, "dir"))
    refute PathCanon.within?(File.join(@root, "dir", "secret"), @root)
    refute PathCanon.within?(File.join(@root, "dir", "missing"), @root)
  end

  def test_missing_leaf_and_missing_intermediates
    assert_equal File.join(@root, "new.txt"), PathCanon.real(File.join(@root, "new.txt"))
    assert_equal "a/b/c", PathCanon.relative(File.join(@root, "a", "b", "c"), @root)
  end

  def test_dot_dot_escaping_root_is_outside
    refute PathCanon.within?(File.join(@root, "..", "outside", "secret"), @root)
    refute PathCanon.within?("../outside/secret", @root)
    assert PathCanon.within?("sub/../file", @root)
  end

  def test_trailing_slashes
    assert PathCanon.within?("#{@root}/a/", "#{@root}/")
    assert_equal ".", PathCanon.relative("#{@root}/", @root)
  end

  def test_sibling_with_shared_prefix_is_outside
    FileUtils.mkdir_p(File.join(@tmp, "rootbar"))
    refute PathCanon.within?(File.join(@tmp, "rootbar", "x"), @root)
  end

  def test_tmp_alias_resolves
    skip "no /tmp alias here" if File.realpath("/tmp") == "/tmp"
    dir = Dir.mktmpdir("pc", "/tmp")
    real = File.realpath(dir)
    assert PathCanon.within?(File.join(dir, "x"), real)
    assert_equal "x", PathCanon.relative(File.join(real, "x"), dir)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_wrong_case_returns_on_disk_case
    FileUtils.mkdir_p(File.join(@root, "Mixed"))
    skip "case-sensitive volume" unless File.exist?(File.join(@root, "mixed"))
    assert_equal File.join(@root, "Mixed"), PathCanon.real(File.join(@root, "mixed"))
  end

  def test_follow_leaf_false_keeps_a_symlink_leaf
    leaf = File.join(@root, "leak")
    File.symlink(File.join(@outside, "secret"), leaf)
    assert_equal leaf, PathCanon.real(leaf, follow_leaf: false)
    assert PathCanon.within?(leaf, @root, follow_leaf: false)
    refute PathCanon.within?(leaf, @root)
  end

  def test_follow_leaf_false_still_resolves_the_parent
    File.symlink(@outside, File.join(@root, "dir"))
    refute PathCanon.within?(File.join(@root, "dir", "secret"), @root, follow_leaf: false)
  end

  def test_relative_is_nil_outside_and_dot_at_root
    assert_nil PathCanon.relative(@outside, @root)
    assert_equal ".", PathCanon.relative(@root, @root)
    assert PathCanon.within?(@root, @root)
  end

  def test_real_never_raises
    assert_kind_of String, PathCanon.real(nil)
    assert_kind_of String, PathCanon.real("\0bad")
    locked = File.join(@root, "locked")
    FileUtils.mkdir_p(File.join(locked, "inner"))
    File.chmod(0o000, locked)
    assert_kind_of String, PathCanon.real(File.join(locked, "inner", "x"))
    assert PathCanon.within?(File.join(locked, "inner", "x"), @root)
  end

  def test_dangling_symlink_resolves_to_its_own_path
    leaf = File.join(@root, "dangling")
    File.symlink(File.join(@tmp, "nowhere"), leaf)
    assert_equal leaf, PathCanon.real(leaf)
  end

  def test_a_symlink_is_followed_before_a_parent_segment
    Dir.mktmpdir do |dir|
      root = File.join(dir, "walkthrough")
      outside = File.join(dir, "outside", "nested")
      FileUtils.mkdir_p([ root, outside ])
      File.symlink(outside, File.join(root, "jump"))
      File.write(File.join(dir, "outside", "seed.json"), "{}")

      refute PathCanon.within?("jump/../seed.json", root)
      assert_equal File.realpath(File.join(dir, "outside", "seed.json")), PathCanon.real("jump/../seed.json", base: root)
    end
  end
end
