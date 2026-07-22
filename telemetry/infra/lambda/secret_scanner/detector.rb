# Capability C - Detector (plan section 6.4). Curated pure-Ruby regex ruleset plus
# a Shannon-entropy-gated generic catch-all. Deliberately isolated behind this
# module so a bundled gitleaks/trufflehog binary could be swapped in later as a
# contained change (plan section 12).

module Detector
  # Ordered rule table, patterns copied verbatim from plan section 6.4.
  RULES = [
    { rule_id: "aws_access_key_id",     regex: /AKIA[0-9A-Z]{16}/ },
    { rule_id: "aws_secret_access_key", regex: /(?i)aws.{0,20}(secret|sk).{0,20}['"][A-Za-z0-9\/+=]{40}['"]/ },
    { rule_id: "github_pat",            regex: /gh[pousr]_[A-Za-z0-9]{36}/ },
    { rule_id: "github_fine_grained",   regex: /github_pat_[0-9a-zA-Z_]{82}/ },
    { rule_id: "slack_token",           regex: /xox[baprs]-[A-Za-z0-9-]{10,48}/ },
    { rule_id: "slack_webhook",         regex: /https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9\/]{40,}/ },
    { rule_id: "google_api_key",        regex: /AIza[0-9A-Za-z\-_]{35}/ },
    { rule_id: "stripe_secret_key",     regex: /sk_live_[0-9a-zA-Z]{24,}/ },
    { rule_id: "npm_token",             regex: /npm_[A-Za-z0-9]{36}/ },
    { rule_id: "jwt",                   regex: /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/ },
    { rule_id: "private_key_block",     regex: /-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/ },
    { rule_id: "generic_assignment",    regex: /(?i)(secret|token|passwd|password|api[_-]?key)\s*[:=]\s*['"]([^'"\n]{16,})['"]/ }
  ].freeze

  # generic_assignment only counts when the captured value's Shannon entropy
  # exceeds this threshold (bits/char), keeping the catch-all off prose.
  ENTROPY_THRESHOLD = 3.5

  # Cap the masked preview so a huge match cannot bloat a notification row.
  MAX_PREVIEW = 40
  PREVIEW_PREFIX = 4

  # Standard Shannon entropy: sum of -p*log2(p) over character frequencies.
  def self.shannon_entropy(str)
    return 0.0 if str.nil? || str.empty?

    len = str.length.to_f
    freq = Hash.new(0)
    str.each_char { |c| freq[c] += 1 }
    freq.values.reduce(0.0) do |acc, count|
      p = count / len
      acc - (p * Math.log2(p))
    end
  end

  # Keep a short prefix, mask the rest with '*' up to the matched length,
  # capped at MAX_PREVIEW characters total.
  def self.mask(matched)
    text = matched.to_s
    visible = text[0, PREVIEW_PREFIX] || ""
    total = [ text.length, MAX_PREVIEW ].min
    masked_len = [ total - visible.length, 0 ].max
    visible + ("*" * masked_len)
  end

  # Returns [{ rule_id:, match_offset:, masked_preview: }, ...] for every rule
  # that fires anywhere in body.
  def self.scan_text(body)
    findings = []
    return findings if body.nil? || body.empty?

    RULES.each do |rule|
      body.to_enum(:scan, rule[:regex]).each do
        m = Regexp.last_match
        matched = m[0]

        if rule[:rule_id] == "generic_assignment"
          # Gate on entropy of the captured value (group 2 in this pattern).
          value = m[2].to_s
          next if shannon_entropy(value) <= ENTROPY_THRESHOLD
        end

        findings << {
          rule_id: rule[:rule_id],
          match_offset: m.begin(0),
          masked_preview: mask(matched)
        }
      end
    end
    findings
  end
end
