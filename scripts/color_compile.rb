#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'json'
require 'tmpdir'
require_relative 'change_docker'

# Decides whether a token file needs a Tailwind build before a browser can
# read it, and runs that build in the project's own pinned Node image when it
# does. This is a routing heuristic, not a CSS parser: a false positive (a
# file that mentions "@theme" in a comment, say) only costs an unnecessary
# compile, never a wrong answer, since Tailwind's own CLI is what actually
# reads the file afterward.
module ColorCompile
  # Any of these in the file's text routes it through a Tailwind build first.
  # @import is included because an unbundled @import is something only a
  # bundler (Tailwind's own CLI, which wraps lightningcss) can resolve; the
  # others are Tailwind's own at-rules.
  ROUTING_DIRECTIVES = %w[@import @theme @tailwind @apply @source @plugin @config
                          @custom-variant @utility @variant @reference].freeze
  # The subset that is Tailwind-specific rather than plain bundling, so a
  # missing-install error can tell the two apart: a file with nothing but a
  # plain @import is not "using Tailwind", it just cannot be bundled without
  # Tailwind's CLI standing in for one.
  TAILWIND_DIRECTIVES = (ROUTING_DIRECTIVES - %w[@import]).freeze

  # A plain semver version, the only shape interpolated into the npm package
  # spec, so a package.json version can never smuggle in a file: spec, a
  # range, a tag or shell text.
  SEMVER = /\A\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?\z/.freeze

  # Exactly one of css/error is non-nil.
  Result = Data.define(:css, :error)

  module_function

  # True when `text` (with comments blanked first, so a directive mentioned
  # only in a comment does not trigger a build) mentions any routing
  # directive.
  def needs_compile?(text)
    stripped = strip_comments(text)
    ROUTING_DIRECTIVES.any? { |d| mentions?(stripped, d) }
  end

  def strip_comments(text)
    text.gsub(%r{/\*.*?\*/}m, ' ')
  end

  def mentions?(text, directive)
    text.match?(/(?<![\w-])#{Regexp.escape(directive)}(?![\w-])/)
  end

  # Reads `path_abs`, compiling it through the repo's own installed Tailwind
  # (found under `root_abs`) first when it needs one. A file outside the root
  # that needs a compile is an error: the compile mounts only the root, so
  # the container could not see it. Returns a Result.
  def read(root_abs, path_abs)
    text = File.read(path_abs, encoding: 'UTF-8')
    return Result.new(css: text, error: nil) unless needs_compile?(text)

    prefix = root_abs.end_with?(File::SEPARATOR) ? root_abs : root_abs + File::SEPARATOR
    unless path_abs.start_with?(prefix)
      return Result.new(css: nil, error: "#{path_abs} is outside the scan root #{root_abs}; the Tailwind compile " \
                                         'mounts only the root, so pass a root that contains it')
    end

    compile(root_abs, path_abs.delete_prefix(prefix), text)
  end

  def compile(root, relative_path, text)
    version = tailwindcss_version(root)
    return Result.new(css: nil, error: missing_tailwind_message(root, relative_path, text)) if version.nil?
    unless version.is_a?(String) && SEMVER.match?(version)
      return Result.new(css: nil, error: "#{relative_path}: node_modules/tailwindcss/package.json has version " \
                                         "#{version.inspect}, which is not a plain semver version; reinstall dependencies")
    end

    major = version.split('.').first.to_i
    cli = tailwind_cli_package(major, version)
    return Result.new(css: nil, error: "#{relative_path}: tailwindcss #{version} is major #{major}, which this " \
                                       "checker does not know how to drive (only 3.x and 4.x are supported)") unless cli

    run_build(root, relative_path, cli)
  end

  def missing_tailwind_message(root, relative_path, text)
    if TAILWIND_DIRECTIVES.any? { |d| mentions?(strip_comments(text), d) }
      "#{relative_path} uses Tailwind directives but #{File.join(root, 'node_modules/tailwindcss')} is not " \
        'installed; install dependencies first'
    else
      "#{relative_path} has an @import that only a bundler can resolve, and " \
        "#{File.join(root, 'node_modules/tailwindcss')} is not installed to act as one; install dependencies first"
    end
  end

  # The raw package.json version value (any JSON type), or nil only when the
  # package file is missing or unparseable.
  def tailwindcss_version(root)
    pkg = File.join(root, 'node_modules/tailwindcss/package.json')
    return nil unless File.file?(pkg)

    JSON.parse(File.read(pkg))['version']
  rescue StandardError
    nil
  end

  # Major 4 ships its CLI as a separate package; major 3 ships the CLI
  # inside the tailwindcss package itself. Both are pinned to the exact
  # installed version so the build matches what the repo actually resolves.
  def tailwind_cli_package(major, version)
    case major
    when 4 then "@tailwindcss/cli@#{version}"
    when 3 then "tailwindcss@#{version}"
    end
  end

  # The argv `run_build` executes, split out so a test can assert it without
  # running docker. The command is an argument list, never a shell string, so
  # a path with spaces or shell metacharacters stays one argument. The repo is
  # mounted read-only and the empty temp dir is the working directory, so
  # Tailwind's own source detection scans nothing.
  def build_command(root, relative_path, cli, out_dir)
    ChangeDocker.run_command(
      network: nil, image: ChangeDocker::NODE_IMAGE,
      args: [ 'npx', '--yes', cli, '-i', "/repo/#{relative_path}", '-o', '/out/out.css' ],
      env: { 'HOME' => '/tmp', 'npm_config_update_notifier' => 'false' },
      mounts: { File.expand_path(root) => { target: '/repo', readonly: true }, out_dir => '/out' },
      user: "#{Process.uid}:#{Process.gid}", workdir: '/out'
    )
  end

  # The number of trailing stderr/stdout lines kept in a compile-failure
  # message, enough to show the real lightningcss/tailwind error without
  # dumping a whole failed build log.
  STDERR_TAIL_LINES = 20

  def run_build(root, relative_path, cli)
    Dir.mktmpdir('cf-color-tw-out') do |out_dir|
      argv = build_command(root, relative_path, cli, out_dir)
      out, status = Open3.capture2e(*argv)
      unless status.success?
        tail = out.lines.last(STDERR_TAIL_LINES).join
        return Result.new(css: nil, error: "#{relative_path}: tailwind build failed:\n#{tail}")
      end

      out_file = File.join(out_dir, 'out.css')
      unless File.file?(out_file)
        return Result.new(css: nil, error: "#{relative_path}: tailwind build produced no output:\n#{out.lines.last(STDERR_TAIL_LINES).join}")
      end

      Result.new(css: File.read(out_file, encoding: 'UTF-8'), error: nil)
    end
  end
end
