#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

# Renders one cf:code-review finding as a posted PR comment body. Takes a
# JSON finding on stdin ({tier, title, scenario, suggestion?}) and prints the
# final markdown to stdout, so the agent never hand-assembles the template or
# does its own char-budget arithmetic.
class RenderFindingComment
  CHAR_CAP = 640
  BADGES = { 'P1' => '🔴', 'P2' => '🟠', 'P3' => '🟢' }.freeze

  def initialize(finding)
    @tier = finding.fetch('tier')
    @title = finding.fetch('title').strip
    @scenario = finding.fetch('scenario').strip
    @suggestion = finding['suggestion']&.strip
    raise "unknown tier: #{@tier}" unless BADGES.key?(@tier)
  end

  def render
    with_suggestion = body(suggestion: @suggestion)
    return with_suggestion if with_suggestion.length <= CHAR_CAP

    without_suggestion = body(suggestion: nil)
    return without_suggestion if without_suggestion.length <= CHAR_CAP

    body(suggestion: nil, scenario: truncated_scenario(without_suggestion.length))
  end

  private

  def header
    "**#{BADGES.fetch(@tier)} #{@tier} - #{@title}**"
  end

  def body(suggestion:, scenario: @scenario)
    parts = [ header, '', scenario ]
    parts += [ '', "```suggestion\n#{suggestion}\n```" ] if suggestion && !suggestion.empty?
    parts.join("\n")
  end

  def truncated_scenario(current_length)
    overflow = current_length - CHAR_CAP
    budget = @scenario.length - overflow - 3
    return @scenario if budget >= @scenario.length

    "#{@scenario[0, [ budget, 0 ].max]}..."
  end
end

puts RenderFindingComment.new(JSON.parse($stdin.read)).render if __FILE__ == $PROGRAM_NAME
