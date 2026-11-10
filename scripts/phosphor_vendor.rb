#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'prototype_icons'

# Builds the vendored Phosphor subset that walkthrough diagram nodes inline.
#
#   ruby scripts/phosphor_vendor.rb <icons-cache-dir>           rewrite the subset
#   ruby scripts/phosphor_vendor.rb <icons-cache-dir> --check   compare to the committed file
#
# The pinned @phosphor-icons/core tarball comes through PrototypeIcons.fetch
# (npm pack inside the pinned Node image, sha512 checked). Only the path data
# of the curated NAMES in the supported WEIGHTS is kept, so a diagram screen
# can inline an icon with no file and no network at capture time. Adding an
# icon means adding its name here and rerunning; the data file is committed.
module PhosphorVendor
  PKG = ChangeDocker::PHOSPHOR_PKG
  SOURCE = 'https://github.com/phosphor-icons/core'
  VENDOR_DIR = File.join(__dir__, 'vendor', 'phosphor')
  DATA = File.join(VENDOR_DIR, "phosphor-#{PKG[:version]}.json")
  WEIGHTS = %w[regular bold duotone fill].freeze
  NAMES = %w[
    check-circle clipboard-text cloud code database device-mobile devices file-text flow-arrow gauge gear
    git-branch git-commit git-merge git-pull-request list-checks lightning lock person-simple-circle robot
    rocket seal-check shield-check stamp tag terminal test-tube user users warning wheelchair x-circle
  ].freeze
  PATH_RE = /<path d="([^"]+)"(?: opacity="([\d.]+)")?\s*\/>/

  module_function

  # Each icon's paths as [d, opacity-or-nil] pairs, from one Phosphor SVG.
  def paths(svg)
    body = svg[%r{<svg[^>]*>(.*)</svg>}m, 1] or raise "not an SVG: #{svg[0, 60]}"
    found = body.scan(PATH_RE).map { |d, o| o ? [ d, o.to_f ] : [ d ] }
    raise "unsupported SVG content: #{body[0, 80]}" unless body.gsub(PATH_RE, '').strip.empty? && !found.empty?

    found
  end

  def build(pkg_root)
    icons = NAMES.to_h do |name|
      [ name, WEIGHTS.to_h { |w| [ w, paths(PrototypeIcons.phosphor_svg(name, w, root: pkg_root)) ] } ]
    end
    { 'package' => PKG[:name], 'version' => PKG[:version], 'source' => SOURCE, 'license' => 'MIT',
      'view_box' => '0 0 256 256', 'icons' => icons }
  end

  def render(data) = "#{JSON.pretty_generate(data)}\n"
end

if __FILE__ == $PROGRAM_NAME
  cache = ARGV.first || abort('usage: phosphor_vendor.rb <icons-cache-dir> [--check]')
  out = PhosphorVendor.render(PhosphorVendor.build(PrototypeIcons.fetch(PhosphorVendor::PKG, cache)))
  if ARGV.include?('--check')
    abort("#{PhosphorVendor::DATA} does not match a rebuild") unless File.read(PhosphorVendor::DATA) == out
    puts 'phosphor subset matches'
  else
    File.write(PhosphorVendor::DATA, out)
    puts "wrote #{PhosphorVendor::DATA}"
  end
end
