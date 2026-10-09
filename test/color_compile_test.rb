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

  def test_needs_compile_ignores_a_directive_mentioned_only_in_a_comment
    refute ColorCompile.needs_compile?(":root{--a:#fff} /* uses @theme here one day */")
  end

  def test_read_returns_the_file_unchanged_when_no_compile_is_needed
    with_dir do |dir|
      write(dir, "tokens.css", ":root{--a:#fff}")
      result = ColorCompile.read(dir, "tokens.css")
      assert_equal ":root{--a:#fff}", result.css
      assert_nil result.error
    end
  end

  def test_missing_tailwind_install_errors_for_a_tailwind_directive
    with_dir do |dir|
      write(dir, "tokens.css", "@theme static { --color-ink: #222; }\n:root{--a:#fff}")
      result = ColorCompile.read(dir, "tokens.css")
      assert_nil result.css
      assert_includes result.error, "uses Tailwind directives"
      assert_includes result.error, "node_modules/tailwindcss"
      assert_includes result.error, "install dependencies first"
    end
  end

  def test_missing_tailwind_install_errors_differently_for_a_plain_import
    with_dir do |dir|
      write(dir, "tokens.css", "@import \"./extra.css\";\n:root{--a:#fff}")
      result = ColorCompile.read(dir, "tokens.css")
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
      result = ColorCompile.read(dir, "tokens.css")
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
      with_stubbed_build { ColorCompile.read(dir, "tokens.css") }
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

  # The docker argv itself, asserted without running docker: the repo is
  # read-only, the empty temp dir is /out (so Tailwind's own source
  # detection scans nothing), and the input path is under /repo.
  def test_build_command_shape
    with_dir do |dir|
      argv = ColorCompile.build_command(dir, "styles/tokens.css", "@tailwindcss/cli@4.1.14", "/tmp/out-dir")
      assert_equal ChangeDocker::NODE_IMAGE, argv[argv.index("-w") + 2]
      assert_includes argv, "--rm"
      assert_includes argv.each_cons(2).to_a, [ "-v", "#{File.expand_path(dir)}:/repo:ro" ]
      assert_includes argv.each_cons(2).to_a, [ "-v", "/tmp/out-dir:/out" ]
      assert_includes argv.each_cons(2).to_a, [ "-w", "/out" ]
      assert_equal "sh", argv.last(3).first
      script = argv.last
      assert_includes script, "@tailwindcss/cli@4.1.14"
      assert_includes script, "-i /repo/styles/tokens.css"
      assert_includes script, "-o /out/out.css"
    end
  end
end
