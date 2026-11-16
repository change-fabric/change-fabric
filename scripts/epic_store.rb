# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require_relative 'plan_paths'

# Reads a cross-repo epic: one markdown file whose YAML frontmatter points at
# per-repo cf:plan sets that already exist. Parsing never raises on bad input;
# every shape problem becomes a `"<kind>: <detail>"` line on the returned
# Epic, so epic_check can report it beside every other problem at once.
module EpicStore
  Epic = Data.define(:path, :plans_root, :goal, :criteria, :constraints, :repos, :plans, :edges,
                     :epic_rev, :digests, :body, :problems)

  FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m
  LISTS = %w[criteria constraints repos plans edges].freeze
  ENTRY_LISTS = %w[criteria plans edges].freeze
  PHASES_SECTION = /\A##\s+(?:Phases|Phased rollout)\s*\z/
  PHASE_HEADING = /\A###\s+Phase\s+(\d+)\s*:\s*(.+?)\s*\z/

  def self.path_for(slug, root: nil)
    dir = root ? File.join(root, 'epics', slug.to_s) : PlanPaths.plan_dir('epics', slug)
    File.join(dir, 'epic.md')
  end

  def self.load(path, plans_root: PlanPaths.root)
    text = File.read(path)
    match = FRONTMATTER.match(text)
    return empty(path, plans_root, text, [ 'frontmatter: no YAML frontmatter block' ]) unless match

    data = parse_yaml(match[1])
    return empty(path, plans_root, match[2], [ data ]) if data.is_a?(String)

    build(path, plans_root, data, match[2])
  end

  def self.parse_yaml(source)
    data = YAML.safe_load(source, permitted_classes: [])
    data.is_a?(Hash) ? data : 'frontmatter: not a mapping'
  rescue Psych::Exception => e
    "frontmatter: invalid YAML (#{e.message.lines.first.strip})"
  end

  def self.build(path, plans_root, data, body)
    problems = []
    lists = LISTS.to_h { |key| [ key, list(data, key, problems) ] }
    ENTRY_LISTS.each { |key| lists[key] = mappings(lists[key], key, problems) }
    digests = data.fetch('digests', {}) || {}
    unless digests.is_a?(Hash)
      problems << 'frontmatter: digests must be a mapping'
      digests = {}
    end
    Epic.new(path:, plans_root:, goal: data['goal'].to_s, epic_rev: data['epic_rev'], digests:, body:,
             problems:, **lists.transform_keys(&:to_sym))
  end

  def self.list(data, key, problems)
    value = data.fetch(key, []) || []
    return value if value.is_a?(Array)

    problems << "frontmatter: #{key} must be a list"
    []
  end

  def self.mappings(entries, key, problems)
    entries.each_with_index.filter_map do |entry, index|
      next entry.transform_keys(&:to_s) if entry.is_a?(Hash)

      problems << "frontmatter: #{key}[#{index}] must be a mapping"
      nil
    end
  end

  def self.empty(path, plans_root, body, problems)
    Epic.new(path:, plans_root:, goal: '', criteria: [], constraints: [], repos: [], plans: [], edges: [],
             epic_rev: nil, digests: {}, body:, problems:)
  end

  # Phase numbers and titles from `### Phase N: Title` headings, read only
  # inside a `## Phases` or `## Phased rollout` section.
  def self.plan_phases(plan_md)
    inside = false
    plan_md.each_line.filter_map do |line|
      line = line.chomp
      inside = line.match?(PHASES_SECTION) if line.start_with?('## ')
      heading = inside && PHASE_HEADING.match(line)
      [ heading[1].to_i, heading[2] ] if heading
    end
  end

  def self.plan_md_path(epic, plan) = File.join(epic.plans_root, plan['dir'].to_s, 'plan.md')

  # nil when the plan's plan.md is absent; epic_check reports that.
  def self.phases_for(epic, plan)
    path = plan_md_path(epic, plan)
    File.file?(path) ? plan_phases(File.read(path)) : nil
  end

  def self.write_atomic(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp-#{Process.pid}"
    File.write(temp, content)
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if temp && File.exist?(temp)
  end
end
