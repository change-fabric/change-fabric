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
  ensure
    FileUtils.remove_entry(mono) if mono
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
end
