# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/plan_paths"
require_relative "../install"

class PlanPathsTest < Minitest::Test
  include SkillTempHome

  SLUG_TABLE = [
    "cf-plan-skill", "Stripe Webhook Retries", "  leading and trailing  ",
    "Multiple---Hyphens", "under_scores and CAPS", "a", ""
  ].freeze

  def test_slugify_matches_install_skill_name_portable
    SLUG_TABLE.each do |text|
      assert_equal Install::SkillName.portable(text), PlanPaths.slugify(text), "input: #{text.inspect}"
    end
  end

  def test_root_honours_cf_plans_root
    prev = ENV["CF_PLANS_ROOT"]
    ENV["CF_PLANS_ROOT"] = "/srv/plans"
    assert_equal "/srv/plans", PlanPaths.root
  ensure
    ENV["CF_PLANS_ROOT"] = prev
  end

  def test_root_falls_back_to_the_shim_store
    prev = ENV["CF_PLANS_ROOT"]
    ENV["CF_PLANS_ROOT"] = nil
    assert_equal File.join(Dir.home, ".claude", "cf", "plans"), PlanPaths.root
  ensure
    ENV["CF_PLANS_ROOT"] = prev
  end

  def test_root_falls_back_when_cf_plans_root_is_empty
    prev = ENV["CF_PLANS_ROOT"]
    ENV["CF_PLANS_ROOT"] = ""
    assert_equal File.join(Dir.home, ".claude", "cf", "plans"), PlanPaths.root
  ensure
    ENV["CF_PLANS_ROOT"] = prev
  end

  # The default must not encode anybody's personal filing system. This toolkit
  # installs on many machines, so a directory named for one maintainer or for
  # one note-taking method is a bug, not a preference.
  def test_default_root_carries_no_personal_filing_convention
    prev = ENV["CF_PLANS_ROOT"]
    ENV["CF_PLANS_ROOT"] = nil
    relative = PlanPaths.default_root.delete_prefix(Dir.home)
    assert_equal "/.claude/cf/plans", relative
  ensure
    ENV["CF_PLANS_ROOT"] = prev
  end

  # The default is derived the same way ctx derives its own store root, so a
  # session launched with a wrong HOME cannot mint a stray plans tree.
  def test_default_root_uses_the_pinned_home_that_ctx_uses
    prev = ENV["CF_PLANS_ROOT"]
    ENV["CF_PLANS_ROOT"] = nil
    assert PlanPaths.default_root.start_with?("#{CtxPaths.expected_home}/")
  ensure
    ENV["CF_PLANS_ROOT"] = prev
  end

  # No redundant 'plans' segment under a root that is already the plans tree.
  def test_plan_dir_is_area_then_slug_directly_under_the_root
    prev = ENV["CF_PLANS_ROOT"]
    ENV["CF_PLANS_ROOT"] = "/srv/plans"
    assert_equal "/srv/plans/myarea", PlanPaths.plans_dir("myarea")
    assert_equal "/srv/plans/myarea/myslug", PlanPaths.plan_dir("myarea", "myslug")
  ensure
    ENV["CF_PLANS_ROOT"] = prev
  end

  def test_resolve_reports_the_workflow_script_path
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      result = PlanPaths.resolve(area: "a", slug: "s")
      assert_equal File.join(root, "a", "s", "workflow.js"), result[:workflow_js]
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_infer_area_inside_git_repo_returns_toplevel_basename
    Dir.mktmpdir do |parent|
      repo = File.join(parent, "my-repo")
      GitFixture.git_init(repo)
      nested = File.join(repo, "sub", "dir")
      FileUtils.mkdir_p(nested)
      assert_equal "my-repo", PlanPaths.infer_area(cwd: nested)
    end
  end

  def test_infer_area_outside_git_repo_returns_cwd_basename
    Dir.mktmpdir do |dir|
      target = File.join(dir, "plain-project")
      FileUtils.mkdir_p(target)
      assert_equal "plain-project", PlanPaths.infer_area(cwd: target)
    end
  end

  def test_infer_area_at_home_returns_nil
    assert_nil PlanPaths.infer_area(cwd: Dir.home)
  end

  def test_infer_area_at_filesystem_root_returns_nil
    assert_nil PlanPaths.infer_area(cwd: "/")
  end

  def test_resolve_reports_existence_and_siblings_and_suggested_slug
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      area_dir = File.join(root, "myarea")
      FileUtils.mkdir_p(File.join(area_dir, "existing-slug"))
      FileUtils.mkdir_p(File.join(area_dir, "zzz-later"))

      result = PlanPaths.resolve(area: "myarea", slug: "new-slug")
      assert result[:area_exists]
      refute result[:plan_dir_exists]
      assert_equal %w[existing-slug zzz-later], result[:siblings]
      assert_equal "new-slug", result[:suggested_slug]
      assert_equal File.join(area_dir, "new-slug", "plan.md"), result[:plan_md]
      assert_equal File.join(area_dir, "new-slug", "goal.md"), result[:goal_md]
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_resolve_reports_collision_for_existing_slug
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      area_dir = File.join(root, "myarea")
      FileUtils.mkdir_p(File.join(area_dir, "taken"))

      result = PlanPaths.resolve(area: "myarea", slug: "taken")
      assert result[:plan_dir_exists]
      assert_equal "taken-2", result[:suggested_slug]
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_resolve_reports_area_absent_with_no_siblings
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      result = PlanPaths.resolve(area: "nonexistent", slug: "slug")
      refute result[:area_exists]
      assert_equal [], result[:siblings]
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_next_free_slug_skips_taken_suffixes
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      area_dir = File.join(root, "myarea")
      FileUtils.mkdir_p(File.join(area_dir, "slug"))
      FileUtils.mkdir_p(File.join(area_dir, "slug-2"))

      assert_equal "slug-3", PlanPaths.next_free_slug("myarea", "slug")
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_mkdir_is_idempotent_and_creates_nested_parents
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      dir = PlanPaths.plan_dir("brand-new-area", "brand-new-slug")
      refute Dir.exist?(dir)

      out = StringIO.new
      PlanPaths::CLI.run([ "mkdir", "--area", "brand-new-area", "--slug", "brand-new-slug" ], out:)
      assert Dir.exist?(dir)

      # Running it again must not raise and must leave the directory intact.
      PlanPaths::CLI.run([ "mkdir", "--area", "brand-new-area", "--slug", "brand-new-slug" ], out:)
      assert Dir.exist?(dir)
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_cli_resolve_prints_json
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      out = StringIO.new
      PlanPaths::CLI.run([ "resolve", "--slug", "x", "--area", "a" ], out:)
      parsed = JSON.parse(out.string)
      assert_equal "x", parsed["slug"]
      assert_equal "a", parsed["area"]
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_tildeize_collapses_the_home_prefix
    assert_equal "~/code/repo", PlanPaths.tildeize(File.join(Dir.home, "code", "repo"))
  end

  def test_tildeize_leaves_a_path_outside_home_unchanged
    assert_equal "/srv/plans/area/slug", PlanPaths.tildeize("/srv/plans/area/slug")
  end

  def test_tildeize_leaves_bare_home_unchanged
    assert_equal Dir.home, PlanPaths.tildeize(Dir.home)
  end

  def test_resolve_reports_tilde_twins_for_every_path_field
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      result = PlanPaths.resolve(area: "myarea", slug: "myslug")
      assert_equal PlanPaths.tildeize(result[:root]), result[:root_tilde]
      assert_equal PlanPaths.tildeize(result[:area_dir]), result[:area_dir_tilde]
      assert_equal PlanPaths.tildeize(result[:plan_dir]), result[:plan_dir_tilde]
      assert_equal PlanPaths.tildeize(result[:plan_md]), result[:plan_md_tilde]
      assert_equal PlanPaths.tildeize(result[:goal_md]), result[:goal_md_tilde]
      assert_equal PlanPaths.tildeize(result[:workflow_js]), result[:workflow_js_tilde]
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end

  def test_cli_tildeize_prints_the_collapsed_path
    out = StringIO.new
    PlanPaths::CLI.run([ "tildeize", "--path", File.join(Dir.home, "a", "b") ], out:)
    assert_equal "~/a/b", out.string.strip
  end

  def test_cli_tildeize_requires_a_path
    out = StringIO.new
    assert_raises(SystemExit) { PlanPaths::CLI.run([ "tildeize" ], out:) }
    assert_equal({ "error" => "path_required" }, JSON.parse(out.string))
  end

  def test_cli_resolve_reports_area_unresolved_at_home
    Dir.mktmpdir do |root|
      ENV["CF_PLANS_ROOT"] = root
      Dir.chdir(Dir.home) do
        out = StringIO.new
        assert_raises(SystemExit) { PlanPaths::CLI.run([ "resolve", "--slug", "x" ], out:) }
        assert_equal({ "error" => "area_unresolved" }, JSON.parse(out.string))
      end
    ensure
      ENV.delete("CF_PLANS_ROOT")
    end
  end
end
