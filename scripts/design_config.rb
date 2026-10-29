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
module DesignConfig
  class Error < StandardError; end

  Area = Data.define(:match, :status, :reason)
  Roast = Data.define(:auto, :target, :rounds, :max_usd, :model)
  Config = Data.define(:tokens, :tailwind, :figma_url, :figma, :variables_snapshot,
                       :code_connect, :parity_default, :parity_areas, :roast, :critic_rounds)

  DEFAULT_TOKENS = 'design/tokens.css'
  DEFAULT_SNAPSHOT = 'design/figma-variables.json'
  DEFAULT_ROAST = { 'auto' => true, 'target' => 8.5, 'rounds' => 4, 'max_usd' => 2.00, 'model' => nil }.freeze
  DEFAULT_CRITIC_ROUNDS = 3

  module_function

  def load(repo_root)
    path = File.join(repo_root.to_s, 'CHANGE.md')
    front = File.exist?(path) ? ChangeFrontmatter.parse_file(path) : {}
    design = front.is_a?(Hash) ? front.dig('change_config', 'design') : nil
    from_hash(design)
  end

  # tailwind is nil when unset, meaning "auto-detect", which is the caller's job.
  def from_hash(design)
    errors = ChangeSchema.design_errors(design)
    raise Error, errors.join('; ') unless errors.empty?

    design ||= {}
    figma = design['figma'] || {}
    parity = design['parity'] || {}
    roast = DEFAULT_ROAST.merge(design['roast'] || {})
    Config.new(
      tokens: design.fetch('tokens', DEFAULT_TOKENS),
      tailwind: design['tailwind'],
      figma_url: figma['url'],
      figma: figma['url'] && FigmaUrl.parse(figma['url']),
      variables_snapshot: figma.fetch('variables_snapshot', DEFAULT_SNAPSHOT),
      code_connect: figma.fetch('code_connect', false),
      parity_default: parity.fetch('default', 'unreviewed'),
      parity_areas: Array(parity['areas']).map { |a| Area.new(match: a['match'], status: a['status'], reason: a['reason']) }.freeze,
      roast: Roast.new(auto: roast['auto'], target: roast['target'], rounds: roast['rounds'],
                       max_usd: roast['max_usd'], model: roast['model']),
      critic_rounds: design.fetch('critic_rounds', DEFAULT_CRITIC_ROUNDS)
    )
  end
end
