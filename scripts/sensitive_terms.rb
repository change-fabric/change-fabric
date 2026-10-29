# frozen_string_literal: true

# The user-local, never-committed list of sensitive terms
# (~/.claude/cf/sensitive_terms.txt, one per line, '#' comments and blanks
# ignored). Shared by the client-name guard hook and cf:roast. The list may be
# absent, in which case there is nothing to match; any other read error raises.
module SensitiveTerms
  DEFAULT_PATH = File.join(Dir.home, '.claude', 'cf', 'sensitive_terms.txt')

  module_function

  def path = ENV['CF_SENSITIVE_TERMS_FILE'] || DEFAULT_PATH

  def load(terms_path = path)
    File.readlines(terms_path).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
  rescue Errno::ENOENT
    []
  end

  # The terms (case-insensitive) that occur in any of the given texts.
  def matched(texts, terms)
    joined = Array(texts).join("\n")
    terms.select { |term| joined.match?(/#{Regexp.escape(term)}/i) }
  end
end
