# frozen_string_literal: true

require_relative "secret_intake_helpers"

class SecretIntakePresignerTest < Minitest::Test
  Presigner = SecretIntake::Presigner
  NOW = Time.utc(2030, 1, 1, 12)

  def presigner(expiration: nil, token: "TOKEN", region: "us-east-1")
    creds = Presigner::Credentials.new(access_key_id: "AKIDEXAMPLE", secret_access_key: "secret",
                                       session_token: token, expiration: expiration)
    Presigner.new(credentials: creds, region: region, clock: -> { NOW })
  end

  # The presigned GET example from the AWS SigV4 query-auth documentation.
  def test_matches_the_published_aws_vector
    creds = Presigner::Credentials.new(access_key_id: "AKIAIOSFODNN7EXAMPLE",
                                       secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    signer = Presigner.new(credentials: creds, region: "us-east-1", clock: -> { Time.utc(2013, 5, 24) })
    url = signer.sign(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt", expires: 86_400)
    assert url.end_with?("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), url
  end

  def test_put_and_get_share_the_path_style_regional_origin
    signer = presigner(region: "eu-west-2")
    put = URI(signer.url("PUT", "b-key-intake-1", "incoming/secret", expires: 600))
    get = URI(signer.url("GET", "b-key-intake-1", "index.html", expires: 600))
    assert_equal "s3.eu-west-2.amazonaws.com", put.host
    assert_equal put.host, get.host
    assert_equal "/b-key-intake-1/incoming/secret", put.path
    assert_equal "/b-key-intake-1/index.html", get.path
    refute_equal put.query[/X-Amz-Signature=(\h+)/, 1], get.query[/X-Amz-Signature=(\h+)/, 1]
  end

  def test_query_carries_the_session_token_and_signs_host_only
    query = URI.decode_www_form(URI(presigner.url("PUT", "b", "k", expires: 600)).query).to_h
    assert_equal "TOKEN", query["X-Amz-Security-Token"]
    assert_equal "host", query["X-Amz-SignedHeaders"]
    assert_equal "600", query["X-Amz-Expires"]
    assert_equal "AKIDEXAMPLE/20300101/us-east-1/s3/aws4_request", query["X-Amz-Credential"]
  end

  def test_method_changes_the_signature
    signer = presigner
    refute_equal signer.url("PUT", "b", "k", expires: 600), signer.url("GET", "b", "k", expires: 600)
  end

  def test_expires_clamps_to_twelve_hours
    assert_equal 43_200, presigner.expires_for(86_400)
    assert_equal 3600, presigner.expires_for(3600)
  end

  def test_expires_clamps_to_credential_expiry
    assert_equal 1800, presigner(expiration: NOW + 1800).expires_for(3600)
  end

  def test_expired_session_refuses
    assert_raises(ArgumentError) { presigner(expiration: NOW + 30).expires_for(3600) }
  end

  def test_parses_export_credentials_output
    creds = Presigner.credentials_from(JSON.generate(SecretIntakeHelpers::CREDENTIALS))
    assert_equal "ASIAFAKEFAKEFAKE", creds.access_key_id
    assert_equal Time.utc(2099, 1, 1), creds.expiration
  end
end
