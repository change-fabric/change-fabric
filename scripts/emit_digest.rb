# frozen_string_literal: true

require 'digest'
require 'json'

# Identity is the digest of the exact bytes written. Volatile slots (URLs,
# timestamps) are replaced by the digest of their content before emitting.
# Verifiers re-emit and compare; they never rebuild the hash from parts.
#
# Format: plain lowercase hex SHA-256, no prefix.
module EmitDigest
  module_function

  # A String is hashed as its raw bytes. Anything else is hashed as its
  # canonical JSON: hash keys stringified and sorted recursively, symbols as
  # strings, array order kept.
  def of(value) = Digest::SHA256.hexdigest(value.is_a?(String) ? value.b : canonical_json(value))

  def canonical_json(value) = JSON.generate(canonicalize(value))

  def canonicalize(value)
    case value
    when Hash then value.map { |key, item| [ key.to_s, canonicalize(item) ] }.sort_by(&:first).to_h
    when Array then value.map { |item| canonicalize(item) }
    when Symbol then value.to_s
    else value
    end
  end
end
