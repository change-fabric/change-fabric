#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders the k6 lane's narrative section for the Markdown report. A raw k6
# metrics table answers "did the thresholds pass"; a go/no-go reader (often not
# an engineer) needs the story around the number: what real-world peak the app
# must survive, what it was actually tested to, how large the safety margin is,
# how it degrades when deliberately pushed past its ceiling, and a relatable
# comparison for the scale.
#
# Every input is supplied by the project's config under `lanes.k6.scenario`, so
# the funnel assumptions and the comparison point are the project's own (a
# marketing-campaign funnel for one app looks nothing like another's). Nothing
# here is hardcoded to any product; an absent section is simply skipped, so a
# project that supplies only a funnel still gets a coherent, shorter narrative.
#
# The expected peak is derived from the funnel with the project's stated
# assumptions, and when the config also gives a tested sustained rate in the same
# unit the safety-margin multiple is computed rather than asserted.
class ChangeK6Narrative
  def self.section(scenario)
    return nil unless scenario.is_a?(Hash) && !scenario.empty?

    new(scenario).render
  end

  def initialize(scenario)
    @scenario = scenario
  end

  def render
    parts = [ '## Load test narrative', '' ]
    parts.concat(assumptions_lines)
    parts.concat(funnel_lines)
    parts.concat(tested_lines)
    parts.concat(margin_lines)
    parts.concat(overload_lines)
    parts.concat(comparison_lines)
    "#{parts.join("\n").rstrip}\n"
  end

  private

  def window = @scenario.fetch('window', 'per minute').to_s

  def assumptions_lines
    text = @scenario['assumptions'].to_s
    return [] if text.empty?

    [ "Assumptions (deliberately pessimistic in the app's favor, so the conclusion is conservative): #{text}", '' ]
  end

  # Walks the funnel to a derived expected peak, printing each stage and the
  # running total so the derivation is auditable, not asserted.
  def funnel_lines
    stages = Array(@scenario['funnel'])
    return explicit_peak_lines if stages.empty?

    lines = [ 'Expected real-world peak, derived from the campaign funnel:', '' ]
    running = nil
    stages.each do |stage|
      running = apply_stage(running, stage)
      lines << "- #{stage_label(stage)} -> #{format_number(running)}"
    end
    @derived_peak = running
    lines << ''
    lines << "Expected peak: about #{format_number(expected_peak)} #{window}."
    lines << ''
    lines
  end

  def explicit_peak_lines
    return [] unless @scenario['expected_peak']

    [ "Expected real-world peak: #{@scenario['expected_peak']} #{window}.", '' ]
  end

  def apply_stage(running, stage)
    return stage['value'].to_f if stage.key?('value') || stage.key?(:value)
    return (running || 0) * stage['rate'].to_f if stage.key?('rate') || stage.key?(:rate)

    running
  end

  def stage_label(stage)
    name = stage['stage'].to_s
    if stage['rate']
      "#{name} (#{(stage['rate'].to_f * 100).round(2)}%)"
    else
      name
    end
  end

  def expected_peak
    explicit = @scenario['expected_peak']
    numeric = explicit.to_s[/[\d.]+/]
    return numeric.to_f if numeric

    @derived_peak
  end

  def tested_lines
    text = @scenario['tested_to'].to_s
    return [] if text.empty?

    [ "Tested to: #{text}.", '' ]
  end

  # Prefers a computed multiple when the config gives a tested sustained rate in
  # the same unit as the derived peak; otherwise passes through a stated margin.
  def margin_lines
    computed = computed_margin
    return [ "Safety margin: #{@scenario['safety_margin']}.", '' ] if computed.nil? && @scenario['safety_margin']
    return [] if computed.nil?

    [ "Safety margin: roughly #{format_number(computed)}x the expected peak.", '' ]
  end

  def computed_margin
    peak = expected_peak
    tested = @scenario['tested_rate']
    return nil unless peak && peak.to_f.positive? && tested

    (tested.to_f / peak.to_f).round
  end

  def overload_lines
    text = @scenario['overload'].to_s
    return [] if text.empty?

    [ "Deliberate over-the-ceiling burst: #{text}.", '' ]
  end

  def comparison_lines
    text = @scenario['comparison'].to_s
    return [] if text.empty?

    [ "For scale: #{text}.", '' ]
  end

  # Whole numbers print without a trailing .0; fractional volumes keep two
  # places so a funnel that lands on 1.25/min still reads sensibly.
  def format_number(value)
    return value.to_s unless value.is_a?(Numeric)

    value == value.to_i ? value.to_i.to_s : format('%.2f', value)
  end
end
