# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/ctx_paths"

# The dashed-cwd key and the home-prefix invariant are the foundation of the
# store keying, so they get a focused test even though the module is small.
class CtxPathsTest < Minitest::Test
  HOME = "/Users/pst"
  CWD = "/Users/pst/code/pst/pstaylor-patrick/skills"

  def test_dashed_replaces_every_slash
    assert_equal "-Users-pst-code-pst-pstaylor-patrick-skills", CtxPaths.dashed(CWD)
  end

  def test_store_dir_keys_under_home
    assert_equal "#{HOME}/.claude/pst/ctx/-Users-pst-code-x",
                 CtxPaths.store_dir("/Users/pst/code/x", home: HOME)
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

  def test_assert_home_passes_on_expected
    assert CtxPaths.assert_home!(CtxPaths::EXPECTED_HOME)
  end

  def test_assert_home_raises_on_divergent
    assert_raises(CtxPaths::HomeMismatch) { CtxPaths.assert_home!("/home/ci") }
  end
end
