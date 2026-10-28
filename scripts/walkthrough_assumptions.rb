# frozen_string_literal: true

require 'json'
require_relative 'change_docker'
require_relative 'prototype_icons'
require_relative 'walkthrough_storyboard'

# The walkthrough truth trail. The video speaks as a shipped product, so
# everything invented lives here instead: ASSUMPTIONS.md (assumptions,
# invented features, fictional data, brand logos, unsupported claims) and
# THIRD_PARTY_NOTICES for the icon sets the screens use.
module WalkthroughAssumptions
  KINDS = {
    'assumption' => 'Assumptions',
    'invented_feature' => 'Invented features',
    'unsupported_claim' => 'Unsupported claims'
  }.freeze
  HOUDE_HILL = 'This walkthrough is a role plus look-and-feel prototype (Houde and Hill, 1997). ' \
               'It does not demonstrate implementation or integration; nothing shown is built.'

  module_function

  # Scene assumptions grouped by `kind` (default `assumption`), deduplicated
  # by id, each with the scene ids that cite it.
  def grouped(board)
    groups = Hash.new { |h, k| h[k] = {} }
    WalkthroughStoryboard.scenes(board).each do |scene|
      Array(scene['assumptions']).each do |a|
        kind = KINDS.key?(a['kind']) ? a['kind'] : 'assumption'
        entry = groups[kind][a['id']] ||= { 'id' => a['id'], 'text' => a['text'], 'scenes' => [] }
        entry['scenes'] << scene['id']
      end
    end
    groups
  end

  # `seed` is the parsed seed.json (or nil); `logos` is a list of
  # PrototypeIcons.simple_icon-style hashes ({ slug:, title:, license:, guidelines: }).
  def render(board, seed: nil, logos: [])
    groups = grouped(board)
    out = [ "# Assumptions: #{board['title']}", '', HOUDE_HILL, '' ]
    KINDS.each do |kind, heading|
      out << "## #{heading}" << ''
      items = groups[kind].values.sort_by { |e| e['id'].to_s }
      out.concat(items.empty? ? [ 'None recorded.' ] : items.map { |e| "- #{e['id']}: #{e['text']} (scenes: #{e['scenes'].join(', ')})" })
      out << ''
    end
    out << '## Fictional data' << ''
    out.concat(fictional_data(seed))
    out << '' << '## Brand logos' << ''
    out.concat(logos.empty? ? [ 'None used.' ] : logos.map { |logo| logo_line(logo) })
    "#{out.join("\n").rstrip}\n"
  end

  def fictional_data(seed)
    return [ 'No seed data.' ] unless seed.is_a?(Hash) && !seed.empty?

    lines = [ 'Every record in data/seed.json is fictional. Collections:' ]
    seed.keys.sort.each do |name|
      value = seed[name]
      size = value.respond_to?(:size) && !value.is_a?(String) ? " (#{value.size} records)" : ''
      lines << "- #{name}#{size}"
    end
    lines
  end

  def logo_line(logo)
    get = ->(k) { logo[k] || logo[k.to_s] }
    license = get.call(:license)
    license_text = if license.is_a?(Hash)
                     "license: #{[ license['type'] || license[:type], license['url'] || license[:url] ].compact.join(' ')}"
    else
                     'license: CC0-1.0 data (trademark rights remain with the owner)'
    end
    guidelines = get.call(:guidelines) || 'no guidelines link in Simple Icons data; check the brand site before use'
    "- #{get.call(:title) || get.call(:slug)} (#{get.call(:slug)}): guidelines: #{guidelines}; #{license_text}"
  end

  # Icons recorded by PrototypeIcons.copy_used in screens/assets/icons.
  def used_icons(root)
    dir = File.join(root, 'screens', 'assets', 'icons')
    files = Dir.exist?(dir) ? Dir.children(dir).sort : []
    { phosphor: files.any? { |f| f.start_with?('phosphor-') },
      simple_icons: files.filter_map { |f| f[/\Asimple-(.+)\.svg\z/, 1] } }
  end

  # Logo info for each used slug, from the extracted Simple Icons package
  # when it is cached, else the slug alone.
  def resolve_logos(slugs, root)
    pkg_root = PrototypeIcons.package_dir(ChangeDocker::SIMPLE_ICONS_PKG, File.join(root, '.cache', 'icons'))
    slugs.map do |slug|
      PrototypeIcons.simple_icon(slug, root: pkg_root)
    rescue PrototypeIcons::IconNotFoundError
      { slug: slug, title: slug }
    end
  end

  def write(board, root)
    seed_path = File.join(root, 'data', 'seed.json')
    seed = File.file?(seed_path) ? JSON.parse(File.read(seed_path)) : nil
    used = used_icons(root)
    logos = resolve_logos(used[:simple_icons], root)
    assumptions = File.join(root, 'ASSUMPTIONS.md')
    File.write(assumptions, render(board, seed: seed, logos: logos))
    notices = File.join(root, 'THIRD_PARTY_NOTICES')
    File.write(notices, PrototypeIcons.notices(phosphor: used[:phosphor], simple_icons: logos))
    [ assumptions, notices ]
  end
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV[0] || abort('usage: walkthrough_assumptions.rb walkthrough/<slug>/storyboard.json')
  root = File.dirname(File.expand_path(path))
  puts WalkthroughAssumptions.write(WalkthroughStoryboard.load(path), root)
end
