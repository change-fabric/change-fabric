# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'yaml'
require_relative 'prototype_icons'

# Provider icon supply for cf:diagram architecture diagrams. Each provider
# has a committed metadata manifest (skills/diagram/packs/<provider>.yml)
# naming a pinned npm asset pack; the pack itself is fetched by `npm pack`
# inside the pinned Node image, checked against the manifest's sha512, and
# extracted to a cache outside the repo. No provider SVG is ever committed.
#
# A pack icon is inlined byte for byte inside a nested <svg class="icon">
# (placement only, never recolored). When the pack or the slug is not
# available, resolve returns a fallback record and inline draws a vendored
# Phosphor glyph instead, so a diagram always renders.
module CloudIcons
  class Error < StandardError; end

  MARKER = '.cf-integrity'
  COLOR = /#\h{6}\b|#\h{3}\b|(?:rgba?|hsla?)\([^)]*\)/i

  module_function

  def manifest_dirs
    [ ENV.fetch('CF_DIAGRAM_PACKS', nil), File.expand_path('../skills/diagram/packs', __dir__),
      File.join(Dir.home, '.claude', 'skills', 'cf:diagram', 'packs') ].compact
  end

  def providers
    manifest_dirs.flat_map { |dir| Dir.glob(File.join(dir, '*.yml')).map { |p| File.basename(p, '.yml') } }.uniq.sort
  end

  # The provider profile (package pin, group chrome, fallback map), or nil.
  def manifest(provider)
    @manifests ||= {}
    return @manifests[provider] if @manifests.key?(provider)

    path = manifest_dirs.map { |dir| File.join(dir, "#{provider}.yml") }.find { |p| File.file?(p) }
    @manifests[provider] = path && YAML.safe_load_file(path).freeze
  end

  def cache_root = ENV.fetch('CF_CLOUD_ICONS_CACHE', File.join(Dir.home, '.cache', 'change-fabric', 'cloud-icons'))

  def pkg(provider)
    m = manifest(provider) || raise(Error, "no manifest for provider #{provider.inspect}")
    { name: m.fetch('package'), version: m.fetch('version').to_s, integrity: m.fetch('integrity') }
  end

  def pack_dir(provider, root = cache_root) = File.join(root, provider, pkg(provider)[:version])

  # Fetches, verifies, and extracts one provider pack into the cache,
  # returning its directory. Skips the fetch when the marker records the pin.
  def fetch(provider, root: cache_root)
    pin = pkg(provider)
    dest = pack_dir(provider, root)
    return dest if cached?(provider, root)

    work = File.join(root, provider)
    FileUtils.mkdir_p(work)
    out, status = Open3.capture2(*PrototypeIcons.docker_argv(pin, work))
    raise Error, "npm pack failed for #{pin[:name]}@#{pin[:version]}" unless status.success?

    meta = PrototypeIcons.parse_pack(out)
    PrototypeIcons.verify!(pin, meta['integrity'])
    PrototypeIcons.extract(File.join(work, meta.fetch('filename')), dest)
    File.write(File.join(dest, MARKER), "#{pin[:integrity]}\n")
    dest
  end

  def cached?(provider, root = cache_root) = marker_ok?(provider, pack_dir(provider, root))

  def marker_ok?(provider, dir)
    marker = File.join(dir, MARKER)
    File.file?(marker) && File.read(marker).strip == pkg(provider)[:integrity]
  end

  # One extracted pack: its pack.json slug map and the icon files.
  class Pack
    attr_reader :provider, :dir

    def initialize(provider, dir)
      @provider = provider
      @dir = dir
      @meta = JSON.parse(File.read(File.join(dir, 'pack.json')))
    end

    def title = @meta['title']
    def release = @meta['release']

    def slug(name)
      icons = @meta.fetch('icons', {})
      return name if icons.key?(name)

      Array(@meta['aliases']).to_h[name].then { |target| target if icons.key?(target) }
    end

    def entry(name) = (s = slug(name)) && @meta['icons'][s].merge('slug' => s)

    def file(name)
      e = entry(name)
      path = e && File.join(dir, 'icons', e['file'])
      path && File.file?(path) ? File.binread(path) : nil
    end

    def sha(name) = (f = file(name)) && Digest::SHA256.hexdigest(f)

    # Every color literal the pack's own file for this slug carries.
    def colors(name) = (f = file(name)) ? CloudIcons.colors(f) : []
  end

  # Where packs come from: an explicit provider => dir map (tests use the
  # synthetic fake pack this way) or the verified cache. Never fetches.
  class Store
    def self.cache(root = CloudIcons.cache_root)
      dirs = CloudIcons.providers.filter_map do |p|
        dir = CloudIcons.pack_dir(p, root)
        [ p, dir ] if CloudIcons.marker_ok?(p, dir)
      end
      new(dirs.to_h)
    end

    def initialize(dirs) = @dirs = dirs

    def pack(provider)
      @packs ||= {}
      return @packs[provider] if @packs.key?(provider)

      dir = @dirs[provider]
      @packs[provider] = dir && File.file?(File.join(dir, 'pack.json')) ? Pack.new(provider, dir) : nil
    end
  end

  def colors(text) = text.scan(COLOR).map(&:upcase).uniq

  # A pack record, or a fallback record naming the Phosphor glyph to draw.
  def resolve(provider, slug, store: Store.cache)
    pack = store.pack(provider)
    return fallback(provider, slug, "#{provider} pack is not cached") unless pack

    body = pack.file(slug)
    return fallback(provider, slug, "#{provider} pack has no icon #{slug.inspect}") unless body

    entry = pack.entry(slug)
    { kind: :pack, provider: provider, slug: entry['slug'], title: entry['title'], sha: pack.sha(slug), svg: body }
  end

  def fallback(provider, slug, reason)
    map = manifest(provider)&.dig('fallback') || {}
    glyph = map.dig('slugs', slug) || map['default'] || 'cloud'
    { kind: :fallback, provider: provider, slug: slug, glyph: glyph, label: slug, reason: reason }
  end

  # Markup for one icon at box [x, y, w, h]: a <g class="icon"> carrying the
  # provenance attributes around a nested <svg class="icon">. A pack body is
  # the file's own children, unmodified; a fallback is a Phosphor path.
  def inline(provider, slug, instance_id:, box:, store: Store.cache)
    rec = resolve(provider, slug, store: store)
    x, y, w, h = box
    place = %(x="#{x}" y="#{y}" width="#{w}" height="#{h}")
    if rec[:kind] == :pack
      <<~SVG.chomp
        <g class="icon" id="#{instance_id}" data-provider="#{provider}" data-icon="#{rec[:slug]}" data-pack-sha="#{rec[:sha]}">
          <!-- #{notice_comment(provider)} -->
          <svg class="icon" #{place} viewBox="#{view_box(rec[:svg])}">#{inner(rec[:svg])}</svg>
        </g>
      SVG
    else
      <<~SVG.chomp
        <g class="icon" id="#{instance_id}" data-provider="#{provider}" data-icon="#{slug}" data-fallback="#{rec[:glyph]}">
          <svg class="icon" #{place} viewBox="0 0 256 256">#{phosphor_paths(rec[:glyph])}</svg>
        </g>
      SVG
    end
  end

  def view_box(svg)
    tag = svg[/<svg\b[^>]*>/m].to_s
    vb = tag[/viewBox="([^"]+)"/, 1]
    return vb if vb

    "0 0 #{tag[/width="(\d+(?:\.\d+)?)/, 1] || 64} #{tag[/height="(\d+(?:\.\d+)?)/, 1] || 64}"
  end

  # The root element's children, verbatim: everything between the opening
  # <svg ...> tag and the final </svg>.
  def inner(svg)
    open = svg.match(/<svg\b[^>]*>/m)
    close = svg.rindex('</svg>')
    raise Error, 'pack icon has no <svg> root' unless open && close

    svg[open.end(0)...close]
  end

  def phosphor_paths(glyph)
    data = phosphor_data
    paths = data.dig('icons', glyph, 'regular') || data.dig('icons', 'cloud', 'regular')
    paths.map { |(d)| %(<path d="#{d}" fill="var(--ink)"/>) }.join
  end

  def phosphor_data
    @phosphor_data ||= JSON.parse(File.read(File.expand_path('vendor/phosphor/phosphor-2.1.1.json', __dir__))).freeze
  end

  def notice_comment(provider)
    m = manifest(provider)
    "#{m['title']}: #{m['terms']} (fetched via #{m['package']}@#{m['version']})"
  end

  # THIRD_PARTY_NOTICES text for the providers a diagram uses. Cites the
  # provider's own terms and the package used to fetch, never the package
  # license as the icons' license.
  def package_license_line(manifest)
    license = manifest['package_license']
    license ? "\nThe package's own pack.json declares #{license}; the terms above govern the icons." : ''
  end

  def notices(providers)
    providers.uniq.filter_map { |p| manifest(p) }.map do |m|
      <<~TEXT
        #{m['title']}
        #{m['attribution']}
        Terms: #{m['terms']}
        Fetched from the npm package #{m['package']}@#{m['version']}, release #{m['release']}, unmodified.#{package_license_line(m)}
      TEXT
    end.join("\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  targets = ARGV.empty? ? CloudIcons.providers : ARGV
  targets.each { |p| puts CloudIcons.fetch(p) }
end
