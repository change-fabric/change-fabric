# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "securerandom"

# A software WebAuthn authenticator for tests: a real OpenSSL key that builds
# authenticatorData and clientDataJSON and signs, so verifier tests exercise
# the genuine cryptography with no recorded secrets. Also a minimal CBOR
# encoder (enough for a COSE_Key) and a console receipt signer.
class SoftAuthenticator
  attr_reader :credential_id, :key

  def self.b64(bytes) = [ bytes ].pack("m0").tr("+/", "-_").delete("=")

  def initialize(alg: :es256)
    @alg = alg
    @key = alg == :es256 ? OpenSSL::PKey::EC.generate("prime256v1") : OpenSSL::PKey.generate_key("ED25519")
    @credential_id = self.class.b64(SecureRandom.random_bytes(32))
  end

  def cose_public_key
    if @alg == :es256
      point = @key.public_key.to_octet_string(:uncompressed).b
      encode({ 1 => 2, 3 => -7, -1 => 1, -2 => point.byteslice(1, 32), -3 => point.byteslice(33, 32) })
    else
      encode({ 1 => 1, 3 => -8, -1 => 6, -2 => @key.raw_public_key })
    end
  end

  def pinned = { credential_id => self.class.b64(cose_public_key) }

  # Returns the assertion fields of an approval proof, base64url encoded.
  def assert(body, rp_id:, origin: nil, type: "webauthn.get", up: true, uv: true, challenge: nil, sign_key: nil, hash_rp_id: nil)
    flags = (up ? 0x01 : 0) | (uv ? 0x04 : 0)
    auth_data = Digest::SHA256.digest(hash_rp_id || rp_id) + [ flags, 7 ].pack("CN")
    client = JSON.generate("type" => type, "challenge" => self.class.b64(challenge || Digest::SHA256.digest(body)),
                           "origin" => origin || "https://#{rp_id}", "crossOrigin" => false)
    signature = sign(sign_key || @key, auth_data + Digest::SHA256.digest(client))
    { "credential_id" => credential_id, "authenticator_data" => self.class.b64(auth_data),
      "client_data_json" => self.class.b64(client), "signature" => self.class.b64(signature) }
  end

  def sign(key, data) = key.is_a?(OpenSSL::PKey::EC) ? key.sign("SHA256", data) : key.sign(nil, data)

  def encode(value)
    case value
    when Integer then value >= 0 ? head(0, value) : head(1, -1 - value)
    when String then value.encoding == Encoding::BINARY ? head(2, value.bytesize) + value : head(3, value.bytesize) + value.b
    when Array then head(4, value.size) + value.map { |item| encode(item) }.join.b
    when Hash then head(5, value.size) + value.map { |key, item| encode(key) + encode(item) }.join.b
    else raise ArgumentError, "cannot encode #{value.class}"
    end
  end

  def head(major, number)
    prefix = major << 5
    if number < 24 then [ prefix | number ].pack("C")
    elsif number < 256 then [ prefix | 24, number ].pack("CC")
    elsif number < 65_536 then [ prefix | 25, number ].pack("Cn")
    elsif number < 2**32 then [ prefix | 26, number ].pack("CN")
    else [ prefix | 27, number ].pack("CQ>")
    end
  end
end

# Signs console receipts with a P-256 key standing in for the KMS key.
class SoftReceiptSigner
  attr_reader :key

  def initialize = @key = OpenSSL::PKey::EC.generate("prime256v1")

  def public_pem = key.public_to_pem

  def receipt(fields, key: @key)
    payload = JSON.generate(fields.sort.to_h)
    { "payload" => payload, "sig" => SoftAuthenticator.b64(key.sign("SHA256", payload)), "key_id" => "test-key" }
  end
end
