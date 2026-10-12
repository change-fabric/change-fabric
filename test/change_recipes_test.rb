# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../scripts/change_schema"
require_relative "../scripts/change_frontmatter"
require_relative "../scripts/change_config"
require_relative "../scripts/change_policy"
require_relative "../scripts/change_apps"

# Pins every recipe under skills/change/reference/recipes to the current
# schema. The site renders these files verbatim, so a recipe that no longer
# loads, or that uses a field ChangeSchema does not know, fails here first.
class ChangeRecipesTest < Minitest::Test
  RECIPES = File.expand_path("../skills/change/reference/recipes", __dir__)
  PLACEHOLDERS = %w[<lane> <profile> <app> <ref>].freeze
  FIELD_SEGMENTS = ChangeSchema::FIELDS.map { |f| f.split(".") }.freeze

  def recipe_dirs
    dirs = Dir.glob(File.join(RECIPES, "*/")).map { |d| d.chomp("/") }.sort
    refute_empty dirs, "no recipes found under #{RECIPES}"
    dirs
  end

  def each_recipe(&)
    recipe_dirs.each(&)
  end

  def change_md(dir) = File.join(dir, "CHANGE.md")
  def front(dir) = ChangeFrontmatter.parse_file(change_md(dir))

  def test_recipe_yml_parses_and_lists_existing_files
    each_recipe do |dir|
      meta = YAML.safe_load_file(File.join(dir, "recipe.yml"))
      name = File.basename(dir)
      %w[title summary order files gitignore notes].each do |key|
        assert meta.key?(key), "#{name}/recipe.yml is missing #{key}"
      end
      assert_includes meta["files"], "CHANGE.md", "#{name}/recipe.yml must list CHANGE.md"
      meta["files"].each do |file|
        assert File.file?(File.join(dir, file)), "#{name}/recipe.yml lists missing file #{file}"
      end
    end
  end

  def test_recipe_orders_are_unique
    orders = recipe_dirs.map { |dir| YAML.safe_load_file(File.join(dir, "recipe.yml"))["order"] }
    assert_equal orders.uniq.size, orders.size, "recipe orders collide: #{orders.inspect}"
  end

  def test_spec_version_matches_the_schema
    each_recipe do |dir|
      assert_equal ChangeSchema::VERSION, front(dir)["spec_version"],
                   "#{File.basename(dir)}/CHANGE.md spec_version is stale"
    end
  end

  # A registry root (change_config.apps) is validated per app through the
  # registry doctor, since a registry root has no lanes of its own; a
  # single-app root loads directly under its default and every named profile.
  def test_config_loads_under_every_profile
    each_recipe do |dir|
      path = change_md(dir)
      config = front(dir)["change_config"]
      if config.key?("apps")
        ChangeAppRegistry.load(path).entries.each do |entry|
          app = YAML.safe_load_file(entry.config_path)["change_config"]
          profile_names(app).each { |p| entry.load(profile: p) }
        end
        refute_match(/error/i, ChangeAppRegistry.doctor(path))
      else
        profile_names(config).each do |p|
          report = ChangeConfig.doctor(path, profile: p)
          refute_match(/^(warning|error)/, report, "#{File.basename(dir)} profile #{p.inspect}")
        end
      end
    end
  end

  def test_policy_constructs
    each_recipe do |dir|
      policy = ChangePolicy.new(front(dir)["change_policy"], change_md(dir))
      refute_empty policy.protected_branches, "#{File.basename(dir)} protects no branch"
    end
  end

  def test_every_field_is_in_the_schema
    each_recipe do |dir|
      paths = leaf_paths(front(dir))
      app_files(dir).each { |file| paths.concat(leaf_paths(YAML.safe_load_file(file))) }
      unknown = paths.reject { |segments| known_path?(segments) }.map { |s| s.join(".") }
      assert_empty unknown, "#{File.basename(dir)} uses fields not in ChangeSchema::FIELDS: #{unknown.join(', ')}"
    end
  end

  def test_env_examples_hold_only_placeholders_and_comments
    Dir.glob(File.join(RECIPES, "*/.env.qa.example")).each do |file|
      File.readlines(file, chomp: true).each_with_index do |line, i|
        next if line.strip.empty? || line.start_with?("#")

        assert_match(/\A[A-Z][A-Z0-9_]*=\S+\z/, line, "#{file}:#{i + 1} is not KEY=placeholder")
      end
    end
  end

  private

  def profile_names(config)
    [ nil, *(config["profiles"] || {}).keys ]
  end

  def app_files(dir)
    apps = front(dir).dig("change_config", "apps") || {}
    apps.values.map { |entry| File.join(dir, entry["config"]) }
  end

  # Every leaf of the document as a segment list. A list of mappings walks into
  # its items under `key[]`; a list of scalars and an empty mapping are leaves.
  def leaf_paths(node, prefix = [])
    case node
    when Hash
      return [ prefix ] if node.empty?

      node.flat_map { |k, v| leaf_paths(v, prefix + [ k.to_s ]) }
    when Array
      hashes = node.grep(Hash)
      return [ prefix ] if hashes.empty?

      key = prefix[0...-1] + [ "#{prefix.last}[]" ]
      hashes.flat_map { |item| leaf_paths(item, key) }
    else
      [ prefix ]
    end
  end

  # A path is known when it equals a FIELDS entry or is a prefix of one (an
  # object node such as an empty profile mapping), with placeholder segments
  # matching any single key.
  def known_path?(segments)
    FIELD_SEGMENTS.any? do |field|
      next false if segments.size > field.size

      segments.each_with_index.all? { |seg, i| seg_match?(field[i], seg) }
    end
  end

  def seg_match?(field_seg, seg)
    return true if field_seg == seg
    return ChangeSchema::LANES.include?(seg) if field_seg == "<lane>"

    PLACEHOLDERS.include?(field_seg)
  end
end
