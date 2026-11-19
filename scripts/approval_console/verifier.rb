# frozen_string_literal: true

require 'digest'
require 'json'
require 'openssl'
require_relative 'canonical'
require_relative 'cbor'

module ApprovalConsole
  # Offline verification of an approval proof against what the caller
  # independently knows: the pinned passkey public keys (COSE, per credential
  # id), the rpId, the pinned receipt public key, and the context the gate
  # computed itself (`expected`). Nothing here trusts the record: the signed
  # body is the source of truth, and every authorization-relevant field of it
  # must equal the expected context.
  #
  # Expiry is online, not offline (the console refuses an approve call outside
  # [created_at, expires_at]); a completed approval keeps verifying after its
  # request expired. This checks only that the body's lifetime is sane.
  #
  # A pass is graded by `level`: :receipt (console receipt verified),
  # :passkey (assertion verified, no receipt) or :local (terminal proof with
  # no receipt, which proves only that the human-run CLI wrote it).
  class Verifier
    Result = Struct.new(:ok, :reason, :level, :totp_step, keyword_init: true) do
      def ok? = ok
    end

    KINDS = %w[webauthn+totp totp-terminal].freeze
    FLAG_UP = 0x01
    FLAG_UV = 0x04
    ES256 = -7
    EDDSA = -8

    class Reject < StandardError; end

    # credentials: { credential_id (base64url) => COSE public key (base64url or raw bytes) }
    # receipt_public_key: PEM text of the pinned console receipt key, or nil.
    def initialize(rp_id:, credentials: {}, receipt_public_key: nil)
      @rp_id = rp_id.to_s
      @credentials = credentials
      @receipt_key = receipt_public_key
    end

    # `expected` holds the gate's own context: type, machine_id, repo, sha,
    # profile, and either items ([{step:, digest:}]) or reason, plus the
    # summary and argv or pr_url for the other types. Every key the type needs
    # must be present and match the body; a missing key is a rejection. `require_receipt` is the `remote` enforcement level.
    def verify(proof, expected:, require_receipt: false)
      raise Reject, 'proof is not an object' unless proof.is_a?(Hash)
      raise Reject, 'expected context is not an object' unless expected.is_a?(Hash)

      proof = stringify(proof)
      kind = proof['kind']
      raise Reject, "unknown proof kind #{kind.inspect}" unless KINDS.include?(kind)

      raw = proof['body']
      body = parse_body(raw)
      match_context(body, stringify(expected))
      step = proof['totp_step']
      raise Reject, 'totp_step is not a non-negative integer' unless step.is_a?(Integer) && step >= 0

      assertion = kind == 'webauthn+totp' ? check_assertion(proof, raw) : nil
      level = check_receipt(proof, kind, [ raw, body ], assertion, step)
      raise Reject, 'a console receipt is required' if require_receipt && level != :receipt

      Result.new(ok: true, level: level, totp_step: step)
    rescue Reject, Canonical::Invalid, Cbor::Error, OpenSSL::OpenSSLError, ArgumentError, KeyError => e
      Result.new(ok: false, reason: e.message)
    end

    # Checks one WebAuthn assertion whose challenge must commit to `source` (any
    # string, not only an approval body), against the pinned credential. Returns
    # the SHA-256 hex of the assertion; raises Reject. Used by the console for
    # the registration and secret-reveal assertions.
    def assertion_sha(fields, source)
      check_assertion(stringify(fields), source)
    end

    # Validates a COSE public key (ES256 or EdDSA) and returns an OpenSSL key.
    def cose_public_key(bytes) = cose_key(Cbor.decode(bytes))

    private

    def stringify(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, stringify(item) ] }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def parse_body(string)
      raise Reject, 'proof has no body' unless string.is_a?(String)

      Canonical.parse(string)
    end

    def match_context(body, expected)
      raise Reject, 'expected context is missing type' unless expected.key?('type')
      raise Reject, 'type does not match the expected context' unless body['type'] == expected['type']

      required = required_keys(expected)
      missing = required.reject { |key| expected.key?(key) }
      raise Reject, "expected context is missing #{missing.join(', ')}" unless missing.empty?

      (required - [ 'items' ]).each do |key|
        raise Reject, "#{key} does not match the expected context" unless body[key] == expected[key]
      end
      match_items(body, expected['items']) if required.include?('items')
    end

    def required_keys(expected)
      extra = Canonical::PER_TYPE[expected['type']]
      raise Reject, "expected context has an unknown type #{expected['type'].inspect}" unless extra

      %w[type machine_id repo sha profile] + extra
    end

    def match_items(body, wanted_items)
      wanted = item_pairs(wanted_items, 'expected items')
      signed = item_pairs(body['items'], 'signed items')
      raise Reject, 'items do not match the expected context' unless signed == wanted && !signed.empty?
    end

    def item_pairs(items, label)
      ok = items.is_a?(Array) && items.all? { |item| item.is_a?(Hash) && item['step'].is_a?(String) && item['digest'].is_a?(String) }
      raise Reject, "#{label} are malformed" unless ok

      items.map { |item| [ item['step'], item['digest'] ] }.sort
    end

    def check_assertion(proof, raw)
      auth_data = decode64(proof['authenticator_data'], 'authenticator_data')
      client_json = decode64(proof['client_data_json'], 'client_data_json')
      signature = decode64(proof['signature'], 'signature')
      check_client_data(client_json, raw)
      check_authenticator_data(auth_data)
      key = pinned_key(proof['credential_id'])
      signed = auth_data + Digest::SHA256.digest(client_json)
      raise Reject, 'passkey signature does not verify' unless valid_signature?(key, signature, signed)

      Digest::SHA256.hexdigest(auth_data + client_json + signature)
    end

    def check_client_data(json, raw)
      data = JSON.parse(json)
      raise Reject, 'client data is not an object' unless data.is_a?(Hash)
      raise Reject, 'client data type is not webauthn.get' unless data['type'] == 'webauthn.get'
      raise Reject, 'origin does not match the rpId' unless data['origin'] == "https://#{@rp_id}"
      raise Reject, 'cross-origin assertion' if data['crossOrigin'] == true

      challenge = decode64(data['challenge'], 'challenge')
      committed = challenge.bytesize == 32 && OpenSSL.fixed_length_secure_compare(challenge, Canonical.challenge(raw))
      raise Reject, 'challenge does not commit to the body' unless committed
    rescue JSON::ParserError
      raise Reject, 'client data is not valid JSON'
    end

    def check_authenticator_data(data)
      raise Reject, 'authenticator data is too short' if data.bytesize < 37
      raise Reject, 'rpIdHash does not match the rpId' unless OpenSSL.fixed_length_secure_compare(data.byteslice(0, 32), Digest::SHA256.digest(@rp_id))

      flags = data.getbyte(32)
      raise Reject, 'user presence flag is not set' if (flags & FLAG_UP).zero?
      raise Reject, 'user verification flag is not set' if (flags & FLAG_UV).zero?
    end

    def pinned_key(credential_id)
      pinned = @credentials[credential_id.to_s] or raise Reject, 'credential is not pinned'
      cose_key(Cbor.decode(cose_bytes(pinned)))
    end

    # A pinned key is base64url text or raw COSE bytes. A COSE map starts with a
    # byte of 0xa0 or above, which is never in the base64url alphabet.
    def cose_bytes(pinned)
      raise Reject, 'pinned key is not a string' unless pinned.is_a?(String)

      raw = pinned.b
      raw.match?(/\A[A-Za-z0-9_-]+\z/) ? decode64(raw, 'pinned key') : raw
    end

    def cose_key(map)
      raise Reject, 'COSE key is not a map' unless map.is_a?(Hash)

      case [ map[1], map[3] ]
      when [ 2, ES256 ] then ec_key(map)
      when [ 1, EDDSA ] then ed_key(map)
      else raise Reject, 'unsupported COSE key type or algorithm'
      end
    end

    def ec_key(map)
      x, y = map[-2], map[-3]
      raise Reject, 'unsupported EC curve' unless map[-1] == 1 && x.is_a?(String) && y.is_a?(String) && x.bytesize == 32 && y.bytesize == 32

      point = "\x04".b + x.b + y.b
      der = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::ObjectId('id-ecPublicKey'), OpenSSL::ASN1::ObjectId('prime256v1') ]),
        OpenSSL::ASN1::BitString(point)
      ]).to_der
      OpenSSL::PKey.read(der)
    end

    def ed_key(map)
      x = map[-2]
      raise Reject, 'unsupported EdDSA curve' unless map[-1] == 6 && x.is_a?(String) && x.bytesize == 32

      OpenSSL::PKey.new_raw_public_key('ED25519', x.b)
    end

    def valid_signature?(key, signature, data)
      key.is_a?(OpenSSL::PKey::EC) ? key.verify('SHA256', signature, data) : key.verify(nil, signature, data)
    rescue OpenSSL::PKey::PKeyError
      false
    end

    def check_receipt(proof, kind, bodies, assertion, step)
      receipt = proof['receipt']
      return (assertion ? :passkey : :local) if receipt.nil?

      raise Reject, 'no receipt public key is pinned' unless @receipt_key
      raise Reject, 'receipt is malformed' unless receipt.is_a?(Hash) && receipt['payload'].is_a?(String)

      key = OpenSSL::PKey.read(@receipt_key)
      unless key.verify('SHA256', decode64(receipt['sig'], 'receipt signature'), receipt['payload'])
        raise Reject, 'receipt signature does not verify'
      end

      match_receipt(parse_payload(receipt['payload']), kind, bodies, assertion, step)
      :receipt
    rescue OpenSSL::PKey::PKeyError
      raise Reject, 'receipt signature does not verify'
    end

    def parse_payload(string)
      raise Reject, 'receipt payload is not valid UTF-8' unless Canonical.utf8?(string)

      payload = JSON.parse(string)
      raise Reject, 'receipt payload is not canonical JSON' unless payload.is_a?(Hash) && Canonical.serialize(payload) == string

      payload
    rescue JSON::ParserError, JSON::GeneratorError
      raise Reject, 'receipt payload is not valid JSON'
    end

    def match_receipt(payload, kind, bodies, assertion, step)
      raw, body = bodies
      channel = assertion ? 'console' : 'terminal'
      checks = {
        'v' => 1, 'kind' => kind, 'machine_id' => body['machine_id'], 'request_id' => body['request_id'],
        'body_sha256' => Canonical.body_sha256(raw), 'assertion_sha256' => assertion,
        'totp_step' => step, 'channel' => channel
      }
      checks.each do |field, value|
        raise Reject, "receipt #{field} does not match the record" unless payload.key?(field) && payload[field] == value
      end
      raise Reject, 'receipt accepted_at is missing' unless Canonical.parse_time(payload['accepted_at'])
    end

    def decode64(value, label)
      text = value.to_s
      raise Reject, "#{label} is not base64url" unless text.match?(/\A[A-Za-z0-9_-]*\z/)

      (text.tr('-_', '+/') + ('=' * ((4 - (text.length % 4)) % 4))).unpack1('m0').b
    rescue ArgumentError
      raise Reject, "#{label} is not base64url"
    end
  end
end
