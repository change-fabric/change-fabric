# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'

# Icon supply for cf:prototype. UI icons come from Phosphor (MIT) and brand
# logos from Simple Icons (CC0 data, trademarks still apply). Both arrive as
# pinned npm tarballs fetched by `npm pack` inside the pinned Node image and
# checked against the sha512 integrity pinned in ChangeDocker; a mismatch
# raises and never falls back to another version.
module PrototypeIcons
  class IntegrityError < StandardError; end
  class IconNotFoundError < StandardError; end

  PACKAGES = { phosphor: ChangeDocker::PHOSPHOR_PKG, simple_icons: ChangeDocker::SIMPLE_ICONS_PKG }.freeze
  MARKER = '.cf-integrity'
  WEIGHTS = %w[thin light regular bold fill duotone].freeze

  PHOSPHOR_NOTICE = <<~TEXT
    Phosphor Icons (@phosphor-icons/core)
    https://github.com/phosphor-icons/core

    MIT License

    Copyright (c) 2023 Phosphor Icons

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
  TEXT

  SIMPLE_ICONS_NOTICE = <<~TEXT
    Simple Icons (simple-icons)
    https://github.com/simple-icons/simple-icons

    The Simple Icons data and SVG files are released under CC0 1.0 Universal
    (https://creativecommons.org/publicdomain/zero/1.0/), except where an icon
    lists its own license below.

    Trademark disclaimer: the brand logos below are trademarks of their
    respective owners. Their use here does not indicate endorsement by, or
    affiliation with, those owners. Each use must follow the brand's own
    guidelines, linked below where the owner publishes them.
  TEXT

  module_function

  def package_dir(pkg, cache_dir)
    File.join(cache_dir, "#{pkg[:name].delete_prefix('@').tr('/', '-')}-#{pkg[:version]}")
  end

  # The pure argv for `npm pack` inside the pinned Node image, writing the
  # tarball into the mounted cache directory and printing JSON metadata.
  def docker_argv(pkg, cache_dir, user: "#{Process.uid}:#{Process.gid}")
    ChangeDocker.run_command(
      network: nil, image: ChangeDocker::NODE_IMAGE,
      args: [ 'npm', 'pack', "#{pkg[:name]}@#{pkg[:version]}", '--json' ],
      env: { 'HOME' => '/tmp', 'npm_config_cache' => '/tmp/.npm', 'npm_config_update_notifier' => 'false' },
      mounts: { File.expand_path(cache_dir) => '/out' }, user: user, workdir: '/out'
    )
  end

  # Fetches and extracts one pinned package, returning its extracted dir.
  # Skips the fetch when the dir exists and its marker records the pin.
  def fetch(pkg, cache_dir)
    dest = package_dir(pkg, cache_dir)
    marker = File.join(dest, MARKER)
    return dest if File.exist?(marker) && File.read(marker).strip == pkg[:integrity]

    FileUtils.mkdir_p(cache_dir)
    out, status = Open3.capture2(*docker_argv(pkg, cache_dir))
    raise "npm pack failed for #{pkg[:name]}@#{pkg[:version]}" unless status.success?

    meta = parse_pack(out)
    verify!(pkg, meta['integrity'])
    extract(File.join(cache_dir, meta.fetch('filename')), dest)
    File.write(marker, "#{pkg[:integrity]}\n")
    dest
  end

  def parse_pack(out)
    parsed = JSON.parse(out[out.index('[')..])
    Array(parsed).first || raise('npm pack returned no package metadata')
  end

  def verify!(pkg, integrity)
    return true if integrity == pkg[:integrity]

    raise IntegrityError, "#{pkg[:name]}@#{pkg[:version]} integrity #{integrity.inspect} does not match the pin"
  end

  def extract(tarball, dest)
    FileUtils.rm_rf(dest)
    FileUtils.mkdir_p(dest)
    _out, status = Open3.capture2e('tar', '-xzf', tarball, '-C', dest, '--strip-components=1')
    raise "could not extract #{File.basename(tarball)}" unless status.success?

    FileUtils.rm_f(tarball)
  end

  def phosphor_path(root, name, weight = 'regular')
    raise ArgumentError, "unknown Phosphor weight #{weight}" unless WEIGHTS.include?(weight)

    file = weight == 'regular' ? "#{name}.svg" : "#{name}-#{weight}.svg"
    File.join(root, 'assets', weight, file)
  end

  def phosphor_svg(name, weight = 'regular', root:)
    path = phosphor_path(root, name, weight)
    raise IconNotFoundError, "Phosphor icon #{name} (#{weight}) not found" unless File.file?(path)

    File.read(path)
  end

  # Simple Icons' title-to-slug rule, used when an entry has no explicit slug.
  def slugify(title)
    title.downcase.gsub('+', 'plus').gsub('.', 'dot').gsub('&', 'and')
         .unicode_normalize(:nfd).gsub(/[^a-z0-9]/, '')
  end

  def simple_icons_data(root)
    path = [ 'data/simple-icons.json', '_data/simple-icons.json' ].map { |rel| File.join(root, rel) }.find { |p| File.file?(p) }
    raise IconNotFoundError, 'Simple Icons data file not found' unless path

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? Array(data['icons']) : data
  end

  # One brand logo: its SVG plus the data fields ASSUMPTIONS.md records.
  def simple_icon(slug, root:)
    entry = simple_icons_data(root).find { |icon| (icon['slug'] || slugify(icon['title'].to_s)) == slug }
    raise IconNotFoundError, "Simple Icons logo #{slug} not found" unless entry

    svg_path = File.join(root, 'icons', "#{slug}.svg")
    raise IconNotFoundError, "Simple Icons SVG for #{slug} not found" unless File.file?(svg_path)

    { svg: File.read(svg_path), hex: entry['hex'], title: entry['title'],
      license: entry['license'], guidelines: entry['guidelines'], slug: slug }
  end

  # Copies only the icons a walkthrough uses into its screens/assets/icons.
  # `names` is a list of { kind: :phosphor|:simple_icons, name:, weight: }.
  def copy_used(names, dest, phosphor_root:, simple_icons_root:)
    FileUtils.mkdir_p(dest)
    names.map do |icon|
      if icon[:kind].to_sym == :phosphor
        weight = icon[:weight] || 'regular'
        target = File.join(dest, "phosphor-#{icon[:name]}-#{weight}.svg")
        File.write(target, phosphor_svg(icon[:name], weight, root: phosphor_root))
      else
        target = File.join(dest, "simple-#{icon[:name]}.svg")
        File.write(target, simple_icon(icon[:name], root: simple_icons_root)[:svg])
      end
      target
    end
  end

  # THIRD_PARTY_NOTICES text. `used` is { phosphor: bool, simple_icons: [info hashes] }.
  def notices(used)
    parts = []
    parts << PHOSPHOR_NOTICE if used[:phosphor]
    logos = Array(used[:simple_icons])
    parts << (SIMPLE_ICONS_NOTICE + logos.map { |logo| logo_line(logo) }.join) unless logos.empty?
    parts.join("\n")
  end

  def logo_line(logo)
    license = logo[:license]
    license_text = license ? " license: #{license['type'] || license[:type]} #{license['url'] || license[:url]}".rstrip : ''
    guidelines = logo[:guidelines] ? " guidelines: #{logo[:guidelines]}" : ''
    "\n  #{logo[:title]} (#{logo[:slug]})#{license_text}#{guidelines}"
  end
end

if __FILE__ == $PROGRAM_NAME
  cache = ARGV[0] || abort('usage: prototype_icons.rb <icons-cache-dir>')
  PrototypeIcons::PACKAGES.each_value { |pkg| puts PrototypeIcons.fetch(pkg, cache) }
end
