# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "json"
require "fileutils"
require_relative "../scripts/prototype_kit"

class PrototypeKitTest < Minitest::Test
  THEME = ":root { --color-primary: #112233; --space-2: 0.5rem; }\n"

  # A workspace with one app and a portal target. lockfile picks the package
  # manager layout (pnpm-lock.yaml, package-lock.json, yarn.lock).
  def with_workspace(lockfile: "pnpm-lock.yaml", kit: "packages/design-kit", source: "tailwind")
    Dir.mktmpdir do |root|
      design = { "targets" => { "portal" => { "source" => source, "theme" => "apps/portal/src/app/globals.css",
                                              "components" => "apps/portal/src/components/ui", "kit" => kit } } }
      File.write(File.join(root, "CHANGE.md"), "#{YAML.dump('change_config' => { 'design' => design })}---\n")
      File.write(File.join(root, lockfile), "") if lockfile
      app = File.join(root, "apps/portal")
      FileUtils.mkdir_p(File.join(app, "src/app"))
      File.write(File.join(app, "package.json"),
                 JSON.generate("name" => "portal", "dependencies" => { "react" => "19.1.0", "react-dom" => "19.1.0" },
                               "devDependencies" => { "tailwindcss" => "4.1.3" }))
      File.write(File.join(app, "src/app/globals.css"), THEME)
      yield root
    end
  end

  def test_package_manager_detection
    with_workspace(lockfile: "pnpm-lock.yaml") { |root| assert_equal "pnpm", PrototypeKit.package_manager(root) }
    with_workspace(lockfile: "package-lock.json") { |root| assert_equal "npm", PrototypeKit.package_manager(root) }
    with_workspace(lockfile: "yarn.lock") { |root| assert_equal "yarn", PrototypeKit.package_manager(root) }
    with_workspace(lockfile: nil) { |root| assert_equal "npm", PrototypeKit.package_manager(root) }
  end

  def test_init_scaffolds_a_private_package_linking_the_live_theme
    with_workspace do |root|
      written = PrototypeKit.init(root, "portal")
      kit = File.join(root, "packages/design-kit")
      %w[package.json components.json src/kit.css src/render.tsx src/registry.tsx build.mjs seed/fixtures.ts
         stubs/next-link.tsx stubs/next-navigation.ts stubs/empty.ts].each do |file|
        assert_includes written, file
        assert File.file?(File.join(kit, file)), "missing #{file}"
      end
      pkg = JSON.parse(File.read(File.join(kit, "package.json")))
      assert_equal true, pkg["private"]
      assert pkg["scripts"]["build"]
      assert_match(/prototype_kit\.rb check --target portal/, pkg["scripts"]["check"])
      assert_equal "19.1.0", pkg["devDependencies"]["react"]
      assert_equal "4.1.3", pkg["devDependencies"]["tailwindcss"]
      css = File.read(File.join(kit, "src/kit.css"))
      assert_includes css, '@import "../../../apps/portal/src/app/globals.css";'
      assert_includes css, '@source "../../../apps/portal/src";'
      assert_includes css, '@source "../dist/components";'
      assert_includes css, "@font-face"
      refute_includes css, "--color-primary", "the kit links the theme, it never copies tokens"
      build = File.read(File.join(kit, "build.mjs"))
      assert_includes build, '"next/link"'
      assert_includes build, '"@": "../../apps/portal/src"'
      assert_includes File.read(File.join(kit, "src/render.tsx")), "prerender"
    end
  end

  def test_build_supplies_require_to_the_esm_ssr_bundle
    with_workspace do |root|
      PrototypeKit.init(root, "portal")
      build = File.read(File.join(root, "packages/design-kit/build.mjs"))
      assert_match(/banner: \{ js: .*createRequire.*const require = /, build)
    end
  end

  def test_non_tailwind_target_still_declares_the_css_compiler
    with_workspace(source: "css") do |root|
      PrototypeKit.init(root, "portal")
      deps = JSON.parse(File.read(File.join(root, "packages/design-kit/package.json")))["devDependencies"]
      assert_equal "4.1.3", deps["@tailwindcss/cli"]
      assert_equal "4.1.3", deps["tailwindcss"]
    end
  end

  def test_init_refuses_to_overwrite_an_existing_kit
    with_workspace do |root|
      FileUtils.mkdir_p(File.join(root, "packages/design-kit"))
      error = assert_raises(PrototypeKit::Error) { PrototypeKit.init(root, "portal") }
      assert_match(/already exists/, error.message)
    end
  end

  def test_unknown_target_and_kitless_target_are_named_errors
    with_workspace do |root|
      assert_raises(DesignConfig::UnknownTarget) { PrototypeKit.init(root, "nope") }
    end
    Dir.mktmpdir do |root|
      error = assert_raises(PrototypeKit::Error) { PrototypeKit.target_config(root, nil) }
      assert_match(/sets no kit/, error.message)
    end
  end

  def test_build_command_mounts_the_workspace_root_and_uses_the_package_manager
    with_workspace do |root|
      config = PrototypeKit.target_config(root, "portal")
      argv = PrototypeKit.build_command(root, config)
      mount = argv[argv.index("--mount") + 1]
      assert_includes mount, File.expand_path(root)
      assert mount.end_with?("target=/repo"), mount
      assert_equal "/repo/packages/design-kit", argv[argv.index("-w") + 1]
      assert_equal %w[corepack pnpm run build], argv.last(4)
    end
    with_workspace(lockfile: "package-lock.json") do |root|
      assert_equal %w[npm run build], PrototypeKit.build_command(root, PrototypeKit.target_config(root, "portal")).last(3)
    end
  end

  def test_build_reports_a_failed_build_and_a_missing_output
    with_workspace do |root|
      PrototypeKit.init(root, "portal")
      failed = Struct.new(:success?).new(false)
      error = assert_raises(PrototypeKit::Error) do
        PrototypeKit.build(root, "portal", runner: ->(_) { [ "kit build: unresolved import next/headers\n", failed ] })
      end
      assert_match(%r{unresolved import next/headers}, error.message)
      ok = Struct.new(:success?).new(true)
      error = assert_raises(PrototypeKit::Error) { PrototypeKit.build(root, "portal", runner: ->(_) { [ "", ok ] }) }
      assert_match(/wrote no dist\/kit\.css/, error.message)
    end
  end

  # The stub compiler stands in for the Tailwind compile of src/kit.css: it
  # returns the live theme plus a utility rule, as a real compile would.
  def live_compiler(root)
    lambda do |_root, _path, _package_root|
      ColorCompile::Result.new(css: "#{File.read(File.join(root, 'apps/portal/src/app/globals.css'))}.p-2{padding:var(--space-2)}\n",
                               error: nil)
    end
  end

  def write_dist(root, css)
    dist = File.join(root, "packages/design-kit/dist")
    FileUtils.mkdir_p(dist)
    File.write(File.join(dist, "kit.css"), css)
  end

  def test_check_is_clean_when_the_kit_matches_the_live_theme
    with_workspace do |root|
      PrototypeKit.init(root, "portal")
      write_dist(root, "#{THEME}.p-2{padding:var(--space-2)}\n")
      assert_empty PrototypeKit.check(root, "portal", compiler: live_compiler(root))
    end
  end

  def test_check_names_the_property_that_drifted_after_a_theme_change
    with_workspace do |root|
      PrototypeKit.init(root, "portal")
      write_dist(root, "#{THEME}.p-2{padding:var(--space-2)}\n")
      File.write(File.join(root, "apps/portal/src/app/globals.css"), THEME.sub("#112233", "#ff0000"))
      findings = PrototypeKit.check(root, "portal", compiler: live_compiler(root))
      assert_equal [ "--color-primary" ], findings.map(&:token)
      assert_match(/#ff0000/, findings.first.to_s)
    end
  end

  def test_check_fails_on_zero_utility_output_and_missing_dist
    with_workspace do |root|
      PrototypeKit.init(root, "portal")
      error = assert_raises(PrototypeKit::Error) { PrototypeKit.check(root, "portal", compiler: live_compiler(root)) }
      assert_match(/run prototype_kit\.rb build first/, error.message)
      write_dist(root, THEME)
      no_utils = ->(*) { ColorCompile::Result.new(css: THEME, error: nil) }
      findings = PrototypeKit.check(root, "portal", compiler: no_utils)
      assert_match(/no utility rules/, findings.map(&:to_s).join)
    end
  end

  def test_cli_exit_codes
    with_workspace do |root|
      out = StringIO.new
      err = StringIO.new
      assert_equal 0, PrototypeKit.cli([ "init", "--target", "portal", "--root", root ], out: out, err: err)
      assert_equal 2, PrototypeKit.cli([ "init", "--target", "portal", "--root", root ], out: out, err: err)
      assert_match(/already exists/, err.string)
      assert_equal 2, PrototypeKit.cli([ "bogus" ], out: out, err: err)
    end
  end
end
