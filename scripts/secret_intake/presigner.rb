# frozen_string_literal: true

require 'json'
require 'openssl'
require 'time'
require 'uri'

module SecretIntake
  # SigV4 query presigning for path-style S3 URLs, GET and PUT alike.
  # `aws s3 presign` signs GET only and the SDK is not a dependency, so this is
  # the small signer. Only `host` is signed and the payload is UNSIGNED-PAYLOAD,
  # so a browser may PUT any body with any Content-Type to the signed key.
  class Presigner
    MAX_EXPIRES = 43_200
    ALGORITHM = 'AWS4-HMAC-SHA256'

    Credentials = Struct.new(:access_key_id, :secret_access_key, :session_token, :expiration, keyword_init: true)

    # Parses `aws configure export-credentials --format process` stdout.
    def self.credentials_from(json)
      data = JSON.parse(json)
      Credentials.new(access_key_id: data.fetch('AccessKeyId'), secret_access_key: data.fetch('SecretAccessKey'),
                      session_token: data['SessionToken'],
                      expiration: data['Expiration'] && Time.parse(data['Expiration']).utc)
    end

    def initialize(credentials:, region:, clock: -> { Time.now.utc })
      @credentials, @region, @clock = credentials, region, clock
    end

    def host = "s3.#{@region}.amazonaws.com"

    # The TTL in seconds after both caps: 12h, and the credential's own expiry
    # (a URL outlives nothing it was signed with). Raises when nothing is left.
    def expires_for(ttl)
      caps = [ ttl.to_i, MAX_EXPIRES ]
      caps << (@credentials.expiration - @clock.call).floor if @credentials.expiration
      seconds = caps.min
      raise ArgumentError, 'the AWS session expires too soon to sign a link; run aws sso login' if seconds < 60

      seconds
    end

    def url(method, bucket, key, expires:)
      path = "/#{bucket}/#{key.split('/').map { |part| encode(part) }.join('/')}"
      sign(method: method, host: host, path: path, expires: expires)
    end

    # The raw signer, public so a known AWS test vector can drive it directly.
    def sign(method:, host:, path:, expires:)
      now = @clock.call.utc
      amz_date = now.strftime('%Y%m%dT%H%M%SZ')
      scope = "#{now.strftime('%Y%m%d')}/#{@region}/s3/aws4_request"
      query = canonical_query(scope, amz_date, expires)
      canonical = [ method, path, query, "host:#{host}\n", 'host', 'UNSIGNED-PAYLOAD' ].join("\n")
      to_sign = [ ALGORITHM, amz_date, scope, OpenSSL::Digest::SHA256.hexdigest(canonical) ].join("\n")
      signature = OpenSSL::HMAC.hexdigest('sha256', signing_key(now.strftime('%Y%m%d')), to_sign)
      "https://#{host}#{path}?#{query}&X-Amz-Signature=#{signature}"
    end

    private

    def canonical_query(scope, amz_date, expires)
      params = {
        'X-Amz-Algorithm' => ALGORITHM,
        'X-Amz-Credential' => "#{@credentials.access_key_id}/#{scope}",
        'X-Amz-Date' => amz_date,
        'X-Amz-Expires' => expires.to_s,
        'X-Amz-SignedHeaders' => 'host'
      }
      params['X-Amz-Security-Token'] = @credentials.session_token if @credentials.session_token
      params.sort.map { |k, v| "#{encode(k)}=#{encode(v)}" }.join('&')
    end

    def signing_key(date)
      [ @region, 's3', 'aws4_request' ].reduce(hmac("AWS4#{@credentials.secret_access_key}", date)) { |k, d| hmac(k, d) }
    end

    def hmac(key, data) = OpenSSL::HMAC.digest('sha256', key, data)

    def encode(value) = URI.encode_www_form_component(value).gsub('+', '%20').gsub('%7E', '~')
  end
end
