# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_paths"

# The dashed-cwd key and the home-prefix invariant are the foundation of the
# store keying, so they get a focused test even though the module is small. The
# keying tests pass home: explicitly and use a neutral fixture path; the guard
# tests run against the real Dir.home (no pin is present in the repo checkout).
class CtxPathsTest < Minitest::Test
  HOME = "/srv/u"
  CWD = "/srv/u/code/proj"

  def test_dashed_replaces_every_slash
    assert_equal "-srv-u-code-proj", CtxPaths.dashed(CWD)
  end

  def test_store_dir_keys_under_home
    assert_equal "#{HOME}/.claude/pst/ctx/-srv-u-code-x",
                 CtxPaths.store_dir("/srv/u/code/x", home: HOME)
  end

  def test_class_index_and_roadmap_paths
    base = CtxPaths.store_dir(CWD, home: HOME)
    assert_equal File.join(base, "active"), CtxPaths.class_dir("active", CWD, home: HOME)
    assert_equal File.join(base, "INDEX.md"), CtxPaths.index(CWD, home: HOME)
    assert_equal File.join(base, "ROADMAP.md"), CtxPaths.roadmap(CWD, home: HOME)
    assert_equal File.join(base, ".ctx-meta", "device"), CtxPaths.meta("device", CWD, home: HOME)
  end

  def test_klass_predicate_excludes_archive
    assert CtxPaths.klass?("truth")
    assert CtxPaths.klass?("active")
    refute CtxPaths.klass?(CtxPaths::ARCHIVE)
    refute CtxPaths.klass?("nonsense")
  end

  def test_expected_home_falls_back_to_running_home_without_a_pin
    assert_equal Dir.home, CtxPaths.expected_home
  end

  def test_assert_home_passes_on_expected
    assert CtxPaths.assert_home!
  end

  def test_assert_home_raises_on_divergent
    assert_raises(CtxPaths::HomeMismatch) { CtxPaths.assert_home!("#{Dir.home}-divergent") }
  end

  def test_project_cwd_accepts_a_path_under_home
    assert CtxPaths.project_cwd?(File.join(Dir.home, "code", "proj"))
    assert CtxPaths.project_cwd?(File.join(Dir.home, "workspace", "areas", "foo"))
  end

  def test_project_cwd_rejects_cwd_outside_home
    refute CtxPaths.project_cwd?("/private/var/folders/sk/abc/T/tmp.X1/demo")
    refute CtxPaths.project_cwd?("/tmp/scratch")
    refute CtxPaths.project_cwd?("/Volumes/ext/repo")
    refute CtxPaths.project_cwd?(Dir.home), "bare home is not a project"
  end

  def test_assert_project_raises_outside_home
    assert CtxPaths.assert_project!(File.join(Dir.home, "code", "proj"))
    assert_raises(CtxPaths::NotAProject) { CtxPaths.assert_project!("/elsewhere/x") }
  end
end
