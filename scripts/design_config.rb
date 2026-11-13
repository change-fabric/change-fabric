#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_frontmatter'
require_relative 'change_schema'
require_relative 'figma_url'

# Reads change_config.design from a repo's root CHANGE.md and returns it with
# every default filled. Precedence everywhere is CLI flag over this block over
# these defaults, so a script applies its own flags on top of what this
# returns. A missing CHANGE.md or a missing block yields all defaults. A
# malformed block raises DesignConfig::Error naming the field; a hook that
# loads this must rescue and stay silent.
#
# Since spec 0.18.0 `load` returns a Targets collection. A repo with
# design.targets gets one Config per target; a repo with the flat form (or no
# block) gets exactly one, synthesized as the target named `default`, the way
# ChangeAppRegistry synthesizes a single app. The shared keys (figma, parity,
# roast, critic_rounds) apply to every target. `from_hash` keeps returning the
# default target's Config so a caller holding only a design block is unchanged.
module DesignConfig
  class Error < StandardError; end
  class UnknownTarget < Error; end

  Area = Data.define(:match, :status, :reason)
  Roast = Data.define(:auto, :target, :rounds, :max_usd, :model, :kind, :audience)
  Config = Data.define(:tokens, :tailwind, :figma_url, :figma, :variables_snapshot,
                       :code_connect, :parity_default, :parity_areas, :roast, :critic_rounds, :target)
  Route = Data.define(:path, :mask)
  Reference = Data.define(:base_url, :routes, :auth)
  # One design target. A synthesized flat target has flat: true, a nil kit and
  # a nil reference, so target mode never engages for it.
  Target = Data.define(:name, :app, :source, :theme, :components, :kit, :output, :reference, :flat) do
    def kit? = !kit.nil?
    def reference? = !reference.nil?
  end

  # Every target by name, plus which one a caller gets when it names none.
  Targets = Data.define(:configs, :default_name) do
    include Enumerable

    def names = configs.keys
    def each(&) = configs.each_value(&)
    def default = configs.fetch(default_name)
    def flat? = default.target.flat

    def target(name)
      return default if name.nil?

      configs.fetch(name.to_s) do
        raise UnknownTarget, "unknown design target '#{name}' (known: #{names.join(', ')})"
      end
    end
  end

  FLAT_TARGET = 'default'

  DEFAULT_TOKENS = 'design/tokens.css'
  DEFAULT_SNAPSHOT = 'design/figma-variables.json'
  DEFAULT_ROAST = { 'auto' => true, 'target' => 8.5, 'rounds' => 4, 'max_usd' => 2.00, 'model' => nil,
                     'kind' => nil, 'audience' => nil }.freeze
  DEFAULT_CRITIC_ROUNDS = 3

  module_function

  def load(repo_root)
    path = File.join(repo_root.to_s, 'CHANGE.md')
    front = File.exist?(path) ? ChangeFrontmatter.parse_file(path) : {}
    config = front.is_a?(Hash) ? front['change_config'] : nil
    config = {} unless config.is_a?(Hash)
    apps = config['apps'].is_a?(Hash) ? config['apps'].keys : []
    targets_from_hash(config['design'], apps: apps)
  end

  # The default target's Config for a bare design block (no apps to check a
  # target's app link against).
  def from_hash(design) = targets_from_hash(design).default

  def targets_from_hash(design, apps: :unchecked)
    errors = ChangeSchema.design_errors(design, apps: apps)
    raise Error, errors.join('; ') unless errors.empty?

    design ||= {}
    shared = shared_config(design)
    targets = design['targets']
    return Targets.new(configs: { FLAT_TARGET => flat_config(design, shared) }.freeze, default_name: FLAT_TARGET) unless targets

    configs = targets.to_h { |name, raw| [ name.to_s, target_config(name.to_s, raw, shared) ] }.freeze
    Targets.new(configs: configs, default_name: design.fetch('default_target', targets.keys.first.to_s))
  end

  # tailwind is nil when unset, meaning "auto-detect", which is the caller's job.
  def flat_config(design, shared)
    tokens = design.fetch('tokens', DEFAULT_TOKENS)
    target = Target.new(name: FLAT_TARGET, app: nil, source: design['tailwind'] ? 'tailwind' : 'tokens', theme: tokens,
                        components: nil, kit: nil, output: nil, reference: nil, flat: true)
    Config.new(tokens: tokens, tailwind: design['tailwind'], target: target, **shared)
  end

  # A target's tokens path is its theme file when the theme is a token or CSS
  # file, so a tokens-reading caller sees the live theme; a tailwind target
  # keeps the default tokens path and sets tailwind.
  def target_config(name, raw, shared)
    target = Target.new(name: name, app: raw['app'], source: raw['source'], theme: raw['theme'],
                        components: raw['components'], kit: raw['kit'], output: raw['output'],
                        reference: reference(raw['reference']), flat: false)
    tailwind = raw['source'] == 'tailwind'
    Config.new(tokens: tailwind ? DEFAULT_TOKENS : raw['theme'], tailwind: tailwind, target: target, **shared)
  end

  def reference(raw)
    return nil unless raw

    routes = raw['routes'].map { |r| Route.new(path: r['path'], mask: Array(r['mask']).freeze) }.freeze
    Reference.new(base_url: raw['base_url'], routes: routes, auth: raw['auth'])
  end

  def shared_config(design)
    figma = design['figma'] || {}
    parity = design['parity'] || {}
    roast = DEFAULT_ROAST.merge(design['roast'] || {})
    {
      figma_url: figma['url'],
      figma: figma['url'] && FigmaUrl.parse(figma['url']),
      variables_snapshot: figma.fetch('variables_snapshot', DEFAULT_SNAPSHOT),
      code_connect: figma.fetch('code_connect', false),
      parity_default: parity.fetch('default', 'unreviewed'),
      parity_areas: Array(parity['areas']).map { |a| Area.new(match: a['match'], status: a['status'], reason: a['reason']) }.freeze,
      roast: Roast.new(auto: roast['auto'], target: roast['target'], rounds: roast['rounds'],
                       max_usd: roast['max_usd'], model: roast['model'],
                       kind: roast['kind'], audience: roast['audience']),
      critic_rounds: design.fetch('critic_rounds', DEFAULT_CRITIC_ROUNDS)
    }
  end
end
