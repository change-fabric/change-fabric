# frozen_string_literal: true

require_relative "test_helpers"

# Pins the shipped cf:php and cf:laravel gates. cf:laravel fires on every PHP
# file in a project with an artisan file and stays off a plain Composer
# project; cf:php fires on any PHP file (Blade views included) and on
# composer.json, so it always sits beside cf:laravel.
class SkillPhpLaravelGateTest < Minitest::Test
  include SkillRegistryHelpers

  def shipped(name) = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == name }

  def test_shipped_laravel_fires_on_any_php_under_artisan
    laravel = shipped("cf:laravel")
    app = project_with("artisan", "app/Models/User.php", "app/Jobs/SendInvoice.php")
    plain = project_with("composer.json", "src/User.php")
    assert laravel.matches?(File.join(app, "app/Models/User.php"), root: app)
    assert laravel.matches?(File.join(app, "app/Jobs/SendInvoice.php"), root: app)
    refute laravel.matches?(File.join(plain, "src/User.php"), root: plain),
           "a plain Composer project (no artisan) must not attach cf:laravel"
    assert laravel.detected?(app)
    refute laravel.detected?(plain)
  ensure
    [ app, plain ].each { |d| FileUtils.remove_entry(d) if d }
  end

  def test_shipped_laravel_finds_artisan_in_a_subdirectory
    laravel = shipped("cf:laravel")
    mono = project_with("apps/api/artisan", "apps/api/app/Models/User.php")
    assert laravel.matches?(File.join(mono, "apps/api/app/Models/User.php"), root: mono)
    assert laravel.detected?(mono), "SessionStart detection must agree with the recursive require gate"
  ensure
    FileUtils.remove_entry(mono) if mono
  end

  # detect and require must agree for every artisan depth, or SessionStart and
  # per-edit routing disagree about whether the project is Laravel.
  def test_shipped_laravel_detect_agrees_with_require_at_every_depth
    laravel = shipped("cf:laravel")
    [ "artisan", "api/artisan", "apps/api/artisan", "services/apps/api/artisan" ].each do |marker|
      dir = project_with(marker, "x.php")
      assert laravel.detected?(dir), "detect missed #{marker}"
      FileUtils.remove_entry(dir)
    end
  end

  def test_shipped_php_fires_on_php_and_composer_json
    php = shipped("cf:php")
    proj = project_with("composer.json", "src/User.php", "resources/views/welcome.blade.php")
    assert php.matches?(File.join(proj, "src/User.php"), root: proj)
    assert php.matches?(File.join(proj, "composer.json"), root: proj)
    assert php.matches?(File.join(proj, "resources/views/welcome.blade.php"), root: proj)
    refute php.matches?(File.join(proj, "README.md"), root: proj)
    assert php.detected?(proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  # The env() restriction is enforced by Larastan's parser-based rule, not a
  # grep that would miss PHP call forms; pin that the skill says so.
  def test_laravel_ci_enables_larastan_env_rule
    body = File.read(File.join(REPO_SKILLS, "laravel/SKILL.md"))
    assert_includes body, "noEnvCallsOutsideOfConfig: true"
    refute_match(/git grep/, body, "the grep-based env() check should be gone")
  end

  # cf:php detection must agree with per-edit routing for nested PHP apps:
  # every marker kind at every depth.
  def test_shipped_php_detect_finds_markers_at_every_depth
    php = shipped("cf:php")
    %w[composer.json .php-version].product([ "", "api/", "apps/api/", "services/apps/api/" ]).each do |name, dir_prefix|
      dir = project_with("#{dir_prefix}#{name}")
      assert php.detected?(dir), "detect missed #{dir_prefix}#{name}"
      FileUtils.remove_entry(dir)
    end
  end
end
