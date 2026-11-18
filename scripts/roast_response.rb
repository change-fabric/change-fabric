# frozen_string_literal: true

require 'json'

# The canonical round-N.response.json shape: the author's accept or rebut for
# each issue in round-N.json, in issue order.
#
#   { "responses": [
#     { "where": "...", "problem": "...", "verdict": "accept", "change": "..." },
#     { "where": "...", "problem": "...", "verdict": "rebut", "reason": "..." } ] }
#
# `where` may be spelled `screen`, as older rounds are. `contested` takes a
# reason like `rebut`. `problems` names every fault at once; `build` writes a
# response from a critic plus one verdict per issue.
module RoastResponse
  VERDICTS = { 'accept' => 'change', 'rebut' => 'reason', 'contested' => 'reason' }.freeze

  class Invalid < StandardError; end

  module_function

  def problems(response, critic)
    rows = response.is_a?(Hash) ? response['responses'] : nil
    return [ 'needs a top-level "responses" array' ] unless rows.is_a?(Array)

    issues = Array(critic.is_a?(Hash) ? critic['issues'] : nil)
    found = rows.each_with_index.flat_map { |row, i| row_problems(row, i) }
    found << "has #{rows.size} response(s) for #{issues.size} issue(s)" unless rows.size == issues.size
    found
  end

  def row_problems(row, index)
    label = "responses[#{index}]"
    return [ "#{label} is not an object" ] unless row.is_a?(Hash)

    found = []
    found << "#{label} needs a problem" if blank?(row['problem'])
    field = VERDICTS[row['verdict']]
    return found << "#{label} verdict must be one of #{VERDICTS.keys.join(', ')}" unless field

    found << "#{label} #{row['verdict']} needs a #{field}" if blank?(row[field])
    found
  end

  def blank?(value) = !value.is_a?(String) || value.strip.empty?

  # One response row per critic issue. Each verdict is a hash with `verdict`
  # and its `change` or `reason`; an accept without a change takes the
  # critic's own fix.
  def build(critic, verdicts)
    issues = Array(critic['issues'])
    raise Invalid, "#{verdicts.size} verdict(s) for #{issues.size} issue(s)" unless verdicts.size == issues.size

    rows = issues.zip(verdicts).map { |issue, v| row_for(issue, v.is_a?(Hash) ? v : {}) }
    response = { 'responses' => rows }
    found = problems(response, critic)
    raise Invalid, found.join('; ') unless found.empty?

    response
  end

  def row_for(issue, verdict)
    row = { 'where' => (issue['where'] || issue['screen']).to_s, 'problem' => issue['problem'].to_s,
            'verdict' => verdict['verdict'] }
    row['change'] = verdict['change'] || issue['fix'] if verdict['verdict'] == 'accept'
    row['reason'] = verdict['reason'] if verdict.key?('reason')
    row.compact
  end

  def accept_all(critic) = build(critic, Array(critic['issues']).map { { 'verdict' => 'accept' } })
end
