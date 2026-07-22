#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'securerandom'
require 'time'
require 'shellwords'

# The `ed25519` gem ships a native C extension. It is assumed installed in the
# runtime, but a missing gem raises LoadError, and LoadError < ScriptError <
# Exception - it is NOT a StandardError. A bare `rescue StandardError` would let
# it escape and crash the hook, breaking this repo's non-negotiable "hooks fail
# silent, never crash" rule. Two defenses, on purpose:
#   1. The require here is guarded, so merely loading this library can never
#      raise - `Ed25519` is simply left undefined and every method below returns
#      nil (callers fail open).
#   2. Callers still wrap their whole body in `rescue Exception` (not just
#      `rescue StandardError`) so any LoadError from a transitive path is caught.
begin
  require 'ed25519'
rescue LoadError
  # Signing is unavailable this run; #signed_payload returns nil, callers fail open.
end

# Ed25519 request-signing helpers shared by presence_probe.rb, secret_alert_poll.rb,
# and secret_ack.rb. Reads the team's private key (base64-encoded 32-byte seed)
# from the macOS login Keychain and builds/signs the canonical byte string per
# the wire contract: fields joined by a single "\n" (LF), no trailing newline,
# UTF-8, each field in plain string form; sig = Base64.strict_encode64 of the
# Ed25519 signature over those bytes.
module Ed25519Signing
  KEYCHAIN_SERVICE = 'change-fabric-presence'

  module_function

  # Raw 32-byte Ed25519 seed for a team, decoded from the base64 value cf-team-join
  # cached in the Keychain, or nil on any failure so callers fail open.
  def private_key_seed(team_id)
    id = team_id.to_s
    return nil if id.empty?

    raw = `security find-generic-password -s #{Shellwords.escape(KEYCHAIN_SERVICE)} -a #{Shellwords.escape(id)} -w 2>/dev/null`
    return nil unless $?.success?

    encoded = raw.strip
    return nil if encoded.empty?

    seed = Base64.decode64(encoded)
    seed.bytesize == 32 ? seed : nil
  rescue StandardError
    nil
  end

  def nonce = SecureRandom.hex(16)

  def timestamp = Time.now.utc.iso8601

  # Given an ordered field-name => value hash (Ruby preserves insertion order,
  # which is the field order the wire contract requires) and a team_id, read the
  # key, sign the canonical bytes, and return the full request payload:
  # the same ordered fields plus a base64 `sig`. Returns nil when the key is
  # unavailable or the gem is missing (fail open).
  def signed_payload(ordered_fields, team_id)
    return nil unless defined?(Ed25519)

    seed = private_key_seed(team_id)
    return nil unless seed

    canonical = canonical_bytes(ordered_fields)
    signing_key = Ed25519::SigningKey.new(seed)
    sig = Base64.strict_encode64(signing_key.sign(canonical))
    ordered_fields.merge('sig' => sig)
  rescue StandardError
    nil
  end

  # The exact bytes that get signed: values in insertion order, stringified,
  # joined by a single LF, no trailing newline, UTF-8.
  def canonical_bytes(ordered_fields)
    ordered_fields.values.map { |v| v.to_s }.join("\n").encode('UTF-8')
  end
end
