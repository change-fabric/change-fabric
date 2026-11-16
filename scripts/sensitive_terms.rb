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

  # The terms (case-insensitive) that occur in any of the given texts. A term
  # must start at a left word boundary (not preceded by a letter or digit), so
  # a term buried inside a hash or a longer word does not match, while a term
  # used as a hostname prefix (term-staging, termstaging.org) still does. A
  # literal escape (backslash n, r, or t, as in JSON or a shell string) also
  # counts as a boundary, so serialized text cannot hide a term at line start.
  def matched(texts, terms)
    joined = Array(texts).join("\n")
    terms.select { |term| joined.match?(/(?:(?<![A-Za-z0-9])|(?<=\\[nrt]))#{Regexp.escape(term)}/i) }
  end

  # Every String inside a nested Hash/Array, so structured input is scanned as
  # its decoded values rather than as escaped serialized text.
  def strings(value)
    case value
    when String then [ value ]
    when Array  then value.flat_map { |v| strings(v) }
    when Hash   then value.flat_map { |k, v| [ *strings(k), *strings(v) ] }
    else []
    end
  end
end
