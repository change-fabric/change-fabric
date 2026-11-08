#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'change_docker'
require_relative 'walkthrough_diagram'

# Builds the vendored xyflow bundle that walkthrough diagram scenes inline.
#
#   ruby scripts/xyflow_vendor.rb           rebuild and rewrite the bundle
#   ruby scripts/xyflow_vendor.rb --check   rebuild and compare to the pin
#
# The build never touches the host toolchain: the build inputs under
# scripts/vendor/xyflow/build are copied to a scratch directory and
# `npm ci` (integrity checked against the committed package-lock.json) plus
# the exact-pinned esbuild run inside the digest-pinned ChangeDocker::NODE_IMAGE.
# The network is used for that install only; the output is one classic IIFE
# that fetches nothing at run time. LICENSES.txt is assembled from the license
# file of every package esbuild actually pulled into the bundle, read from the
# metafile, so a dependency that enters the bundle cannot enter uncredited.
module XyflowVendor
  VENDOR_DIR = File.join(__dir__, 'vendor', 'xyflow')
  BUILD_DIR = File.join(VENDOR_DIR, 'build')
  BUILD_INPUTS = %w[package.json package-lock.json entry.js].freeze
  LICENSES = File.join(VENDOR_DIR, 'LICENSES.txt')
  LICENSE_NAMES = /\A(LICEN[CS]E|COPYING)(\.(md|txt))?\z/i

  # One argv element each, never a shell string, so the quoted define value
  # reaches esbuild intact (an unquoted one would bundle React's dev build).
  ESBUILD_ARGS = [
    'entry.js', '--bundle', '--format=iife', '--minify', '--charset=ascii',
    '--legal-comments=eof', '--loader:.css=text', '--target=es2020',
    '--define:process.env.NODE_ENV="production"',
    '--metafile=meta.json', '--outfile=out.js'
  ].freeze
  INSTALL_ARGS = %w[npm ci --ignore-scripts --no-audit --no-fund].freeze
  NPM_ENV = { 'HOME' => '/tmp', 'npm_config_cache' => '/tmp/.npm', 'npm_config_update_notifier' => 'false' }.freeze

  class CheckFailed < StandardError; end

  module_function

  def bundle_path = WalkthroughDiagram::XYFLOW_BUNDLE

  # Two one-shot containers: the integrity-checked install, which needs the
  # registry, then the bundle step with no network at all.
  def docker_steps(work, user: "#{Process.uid}:#{Process.gid}")
    [
      [ nil, INSTALL_ARGS ],
      [ 'none', [ 'node', 'node_modules/esbuild/bin/esbuild', *ESBUILD_ARGS ] ]
    ].map do |network, args|
      ChangeDocker.run_command(
        network: network, image: ChangeDocker::NODE_IMAGE, args: args, env: NPM_ENV,
        mounts: { File.expand_path(work) => '/w' }, user: user, workdir: '/w'
      )
    end
  end

  # esbuild ships its native binary as an optional per-platform package whose
  # postinstall is skipped by --ignore-scripts; the JS shim still resolves it.
  def build
    Dir.mktmpdir('cf-xyflow') do |work|
      BUILD_INPUTS.each { |name| FileUtils.cp(File.join(BUILD_DIR, name), work) }
      docker_steps(work).each do |argv|
        out, err, status = Open3.capture3(*argv)
        raise "xyflow bundle build failed:\n#{out}#{err}" unless status.success?
      end

      meta = JSON.parse(File.read(File.join(work, 'meta.json')))
      yield File.binread(File.join(work, 'out.js')), licenses(work, meta)
    end
  end

  # One section per bundled package, sorted by name, holding its license text.
  def licenses(work, meta)
    packages = meta.fetch('inputs').keys.filter_map { |path| package_root(path) }.uniq.sort
    sections = packages.map do |root|
      pkg = JSON.parse(File.read(File.join(work, root, 'package.json')))
      text = license_text(File.join(work, root)) || raise("#{pkg['name']} ships no license file")
      "--- #{pkg['name']}@#{pkg['version']} (#{pkg['license']}) ---\n\n#{text.strip}\n"
    end
    "Third-party software bundled in #{File.basename(bundle_path)}\n\n#{sections.join("\n")}"
  end

  def package_root(input)
    match = input.match(%r{\A(.*node_modules/(?:@[^/]+/)?[^/]+)/})
    match && match[1]
  end

  def license_text(dir)
    file = Dir.children(dir).sort.find { |name| name.match?(LICENSE_NAMES) }
    file && File.read(File.join(dir, file))
  end

  def write!
    build do |js, licenses|
      File.binwrite(bundle_path, js)
      File.write(LICENSES, licenses)
      puts "wrote #{bundle_path} (#{js.bytesize} bytes, sha256 #{Digest::SHA256.hexdigest(js)})"
    end
  end

  def check!
    build do |js, _licenses|
      actual = Digest::SHA256.hexdigest(js)
      unless actual == WalkthroughDiagram::XYFLOW_SHA256
        raise CheckFailed, "rebuilt bundle sha256 #{actual} does not match the pin #{WalkthroughDiagram::XYFLOW_SHA256}"
      end

      puts "ok: rebuilt bundle matches #{WalkthroughDiagram::XYFLOW_SHA256}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ARGV.include?('--check') ? XyflowVendor.check! : XyflowVendor.write!
  rescue XyflowVendor::CheckFailed, RuntimeError => e
    warn e.message
    exit 1
  end
end
