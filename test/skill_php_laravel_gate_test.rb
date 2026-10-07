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

  ENV_CHECK = File.read(File.join(REPO_SKILLS, "laravel/SKILL.md"))[/^- `(b=\$\(git merge-base [^`]*)`/, 1]
  ENV_MARKERS = [ "artisan", "api/artisan", "apps/api/artisan", "services/apps/api/artisan" ].freeze
  ENV_CALL = "<?php return ['k' => env('K')];\n"

  # Runs the shipped env() check on a repo whose base commit holds the artisan
  # markers plus `base` files, after `change` mutates the work tree.
  def env_check_passes?(base: {}, &change)
    Dir.mktmpdir do |dir|
      git = ->(*a) { system("git", "-C", dir, *a, out: File::NULL, err: File::NULL) or raise "git #{a.join(' ')}" }
      put = ->(path, body) { FileUtils.mkdir_p(File.dirname(File.join(dir, path))); File.write(File.join(dir, path), body) }
      git.call("init", "-q")
      ENV_MARKERS.each { |m| put.call(m, "") }
      base.each { |path, body| put.call(path, body) }
      git.call("add", "-A")
      git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
      git.call("update-ref", "refs/remotes/origin/HEAD", "HEAD")
      change.call(put, git)
      git.call("add", "-A")
      system("bash", "-c", ENV_CHECK, chdir: dir, out: File::NULL, err: File::NULL)
    end
  end

  def test_env_check_line_present = refute_nil(ENV_CHECK, "env() check line not found")

  # Scope: exactly the config/ dir beside each artisan file is exempt; every
  # other config/ dir in the monorepo is scanned.
  def test_env_check_scope_variants
    allowed = [ "config/app.php", "api/config/app.php", "apps/api/config/app.php", "services/apps/api/config/db.php" ]
    flagged = [ "app/Foo.php", "apps/api/app/Foo.php", "apps/api/src/config.php", "packages/sdk/config/Client.php",
                "apps/api/app/config/Foo.php", "apps/web/config/app.php" ]
    allowed.each { |p| assert env_check_passes? { |put, _| put.call(p, ENV_CALL) }, "flagged #{p}, a config file" }
    flagged.each { |p| refute env_check_passes? { |put, _| put.call(p, ENV_CALL) }, "missed #{p}" }
  end

  # Call shape: any casing or spacing of the helper is flagged; methods,
  # static calls, and other functions are not.
  def test_env_check_call_variants
    flagged = [ "env('K')", "ENV('K')", "Env('K')", "\\eNv('K')", "env ('K')", "['k'=>env('K')]", "match ($x) { default=>env('K') }", "$c ? 1:env('K')" ]
    allowed = [ "$app->env('K')", "$app?->env('K')", "Foo::env('K')", "getenv('K')", "$env('K')", "my_env('K')" ]
    flagged.each { |c| refute env_check_passes? { |put, _| put.call("app/Foo.php", "<?php #{c};\n") }, "missed #{c}" }
    allowed.each { |c| assert env_check_passes? { |put, _| put.call("app/Foo.php", "<?php #{c};\n") }, "flagged #{c}" }
  end

  # Change kind: added, modified, and renamed-and-edited files are scanned; a
  # clean change and a deleted file pass.
  def test_env_check_change_kind_variants
    body = "<?php\n" + (1..40).map { |i| "$a#{i} = #{i};\n" }.join
    refute env_check_passes?(base: { "app/Old.php" => body }) { |put, _| put.call("app/Old.php", body + ENV_CALL) }, "missed modified"
    refute env_check_passes?(base: { "app/Old.php" => body }) { |put, git|
      git.call("mv", "app/Old.php", "app/New.php"); put.call("app/New.php", body + ENV_CALL)
    }, "missed renamed and edited"
    assert env_check_passes?(base: { "app/Old.php" => body }) { |_, git| git.call("rm", "-q", "app/Old.php") }, "flagged a deletion"
    assert env_check_passes? { |put, _| put.call("app/Foo.php", "<?php config('k');\n") }, "flagged a clean change"
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
