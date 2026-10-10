# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../scripts/color_compile"
require_relative "../scripts/change_docker"

class ColorCompileTest < Minitest::Test
  def with_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def test_plain_css_does_not_need_compiling
    refute ColorCompile.needs_compile?(":root { --background: #fff; }")
  end

  ColorCompile::ROUTING_DIRECTIVES.each do |directive|
    define_method("test_needs_compile_detects_#{directive.delete_prefix('@')}") do
      assert ColorCompile.needs_compile?(":root{--a:#fff}\n#{directive} foo;\n"), directive
    end
  end

  def test_needs_compile_on_a_scrubbed_invalid_byte_does_not_raise
    text = "\xff:root{--a:#fff}".b.force_encoding(Encoding::UTF_8).scrub
    refute ColorCompile.needs_compile?(text)
    assert ColorCompile.needs_compile?("\xff@theme{}".b.force_encoding(Encoding::UTF_8).scrub)
  end

  def test_needs_compile_ignores_a_directive_mentioned_only_in_a_comment
    refute ColorCompile.needs_compile?(":root{--a:#fff} /* uses @theme here one day */")
  end

  def test_read_returns_the_file_unchanged_when_no_compile_is_needed
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:#fff}")
      result = ColorCompile.read(dir, File.join(dir, "tokens.css"))
      assert_equal ":root{--a:#fff}", result.css
      assert_nil result.error
    end
  end

  def test_missing_tailwind_install_errors_for_a_tailwind_directive
    with_dir do |dir|
      write(dir, "tokens.css", "@theme static { --color-ink: #222; }\n:root{--a:#fff}")
      result = ColorCompile.read(dir, File.join(dir, "tokens.css"))
      assert_nil result.css
      assert_includes result.error, "uses Tailwind directives"
      assert_includes result.error, "node_modules/tailwindcss"
      assert_includes result.error, "install dependencies first"
    end
  end

  def test_missing_tailwind_install_errors_differently_for_a_plain_import
    with_dir do |dir|
      write(dir, "tokens.css", "@import \"./extra.css\";\n:root{--a:#fff}")
      result = ColorCompile.read(dir, File.join(dir, "tokens.css"))
      assert_nil result.css
      assert_includes result.error, "bundler"
      refute_includes result.error, "uses Tailwind directives"
    end
  end

  def write_fake_tailwind(dir, version)
    pkg = { "version" => version }
    write(dir, "node_modules/tailwindcss/package.json", JSON.generate(pkg))
  end

  def test_tailwind_cli_package_for_major_4_is_the_cli_package
    with_dir do |dir|
      write_fake_tailwind(dir, "4.1.14")
      assert_equal "4.1.14", ColorCompile.tailwindcss_version(dir)
      assert_equal "@tailwindcss/cli@4.1.14", ColorCompile.tailwind_cli_package(4, "4.1.14")
    end
  end

  def test_tailwind_cli_package_for_major_3_is_the_tailwindcss_package_itself
    assert_equal "tailwindcss@3.4.1", ColorCompile.tailwind_cli_package(3, "3.4.1")
  end

  def test_unsupported_major_version_is_an_error_naming_it
    with_dir do |dir|
      write_fake_tailwind(dir, "5.0.0")
      write(dir, "tokens.css", "@tailwind base;\n")
      result = ColorCompile.read(dir, File.join(dir, "tokens.css"))
      assert_nil result.css
      assert_includes result.error, "major 5"
    end
  end

  # A version that is plain semver passes validation and reaches the build
  # (stubbed here, so no docker runs); anything else, including a String
  # carrying shell text or an npm spec, is refused before any command is
  # built.
  def read_with_version(version)
    with_dir do |dir|
      write_fake_tailwind(dir, version)
      write(dir, "tokens.css", "@tailwind base;\n")
      with_stubbed_build { ColorCompile.read(dir, File.join(dir, "tokens.css")) }
    end
  end

  def with_stubbed_build
    original = ColorCompile.method(:run_build)
    eigen = ColorCompile.singleton_class
    eigen.send(:remove_method, :run_build)
    eigen.send(:define_method, :run_build) { |*| ColorCompile::Result.new(css: ":root{}", error: nil) }
    begin
      yield
    ensure
      eigen.send(:remove_method, :run_build)
      eigen.send(:define_method, :run_build, original)
    end
  end

  [ "4.1.14", "4.1.14-beta.1", "3.4.17" ].each do |version|
    define_method("test_version_#{version.tr('.-', '__')}_passes_semver_validation") do
      result = read_with_version(version)
      refute_includes result.error.to_s, "not a plain semver version"
    end
  end

  [ "4.1.14; touch x #", 4, "file:../x", "^4.1.0" ].each_with_index do |version, i|
    define_method("test_version_rejected_#{i}_#{version.to_s.gsub(/\W/, '_')}") do
      result = read_with_version(version)
      assert_nil result.css
      assert_includes result.error, "not a plain semver version"
      assert_includes result.error, version.inspect
    end
  end

  # The docker argv itself, asserted without running docker, over relative
  # paths a shell would split or expand. Each must reach the container as one
  # argument, with no shell in between.
  [ "a b.css", "$(x).css", "x;y.css", "x\"y.css" ].each_with_index do |rel, i|
    define_method("test_build_command_keeps_adversarial_path_#{i}_as_one_argument") do
      with_dir do |dir|
        argv = ColorCompile.build_command(dir, rel, "@tailwindcss/cli@4.1.14", "/tmp/out-dir")
        input = "/repo/#{rel}"
        assert_equal 1, argv.count(input), argv.inspect
        assert_equal input, argv[argv.index("-i") + 1]
        refute_includes argv, "sh"
        refute_includes argv, "-c"
        assert_includes argv, "--rm"
        assert_equal "npx", argv[argv.index(ChangeDocker::NODE_IMAGE) + 1]
        assert_includes argv.each_cons(2).to_a, [ "--user", "#{Process.uid}:#{Process.gid}" ]
        assert_includes argv.each_cons(2).to_a, [ "-w", "/out" ]
        assert_includes argv.each_cons(2).to_a, [ "-e", "HOME=/tmp" ]
        assert_includes argv.each_cons(2).to_a, [ "-e", "npm_config_update_notifier=false" ]
        assert_includes argv.each_cons(2).to_a,
                        [ "--mount", %(type=bind,"source=#{File.expand_path(dir)}",target=/repo,readonly) ]
        assert_includes argv.each_cons(2).to_a, [ "--mount", %(type=bind,"source=/tmp/out-dir",target=/out) ]
        assert_equal [ "npx", "--yes", "@tailwindcss/cli@4.1.14", "-i", input, "-o", "/out/out.css" ], argv.last(7)
      end
    end
  end

  # The build runs in the empty /out, so every default the Tailwind CLI
  # finds relative to its working directory must be handed over explicitly.
  # These enumerate the class: each major's defaults, each candidate name,
  # lookup precedence, and the absent case, all through the real argv.
  def build_args_for(version, root_files)
    with_dir do |dir|
      write_fake_tailwind(dir, version)
      write(dir, "tokens.css", "@tailwind base;\n")
      root_files.each { |name| write(dir, name, "module.exports = {}\n") }
      seen = nil
      original = ColorCompile.method(:run_build)
      eigen = ColorCompile.singleton_class
      eigen.send(:remove_method, :run_build)
      eigen.send(:define_method, :run_build) do |root, rel, cli, extra = []|
        seen = ColorCompile.build_command(root, rel, cli, "/tmp/out-dir", extra)
        ColorCompile::Result.new(css: ":root{}", error: nil)
      end
      begin
        ColorCompile.read(dir, File.join(dir, "tokens.css"))
      ensure
        eigen.send(:remove_method, :run_build)
        eigen.send(:define_method, :run_build, original)
      end
      seen
    end
  end

  def test_every_supported_major_declares_its_cwd_defaults
    [ 3, 4 ].each { |major| assert ColorCompile::CWD_DEFAULTS.key?(major), major.to_s }
  end

  ColorCompile::CWD_DEFAULTS.each do |major, defaults|
    version = "#{major}.0.0"
    defaults.each do |flag, candidates|
      candidates.each do |name|
        define_method("test_v#{major}_passes_root_#{name.tr('.', '_')}_with_#{flag.delete('-')}") do
          argv = build_args_for(version, [ name ])
          assert_equal [ flag, "/repo/#{name}" ], argv.last(2)
          assert_includes argv.each_cons(2).to_a, [ "-w", "/out" ]
        end
      end

      define_method("test_v#{major}_#{flag.delete('-')}_follows_the_cli_lookup_order") do
        argv = build_args_for(version, candidates.reverse)
        assert_equal [ flag, "/repo/#{candidates.first}" ], argv.last(2)
      end

      define_method("test_v#{major}_without_a_root_default_passes_no_#{flag.delete('-')}") do
        argv = build_args_for(version, [])
        refute_includes argv, flag
        assert_equal "/out/out.css", argv.last
      end
    end
  end

  def test_v4_ignores_every_root_v3_config
    argv = build_args_for("4.1.14", ColorCompile::TAILWIND_V3_CONFIG_FILES)
    refute_includes argv, "-c"
    assert_equal "/out/out.css", argv.last
  end

  # No command in the color scripts or their tests is a shell string. The
  # needles are built by concatenation so this file does not match itself.
  def test_no_color_script_or_test_runs_a_shell_string
    needles = [ '"', "'" ].map { |q| %w[sh -c].map { |w| "#{q}#{w}#{q}" }.join(", ") }
    root = File.expand_path("..", __dir__)
    files = Dir[File.join(root, "scripts/*.rb")] + Dir[File.join(root, "test/color_*_test.rb")]
    refute_empty files
    offenders = files.select { |f| needles.any? { |n| File.read(f).include?(n) } }
    assert_empty offenders
  end
end
