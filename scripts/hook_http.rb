#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# Shared POST-JSON-get-JSON helper for the telemetry/presence/secret-alert
# hooks. Every caller already wraps its own body in a fail-open `rescue
# Exception`, so this stays a thin, error-swallowing transport: any failure
# (timeout, DNS, non-2xx, malformed body) returns nil rather than raising,
# so a hook never has to duplicate this rescue to stay fail-open.
module HookHttp
  module_function

  def post_json(url, payload, timeout:)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = timeout
    http.read_timeout = timeout

    request = Net::HTTP::Post.new(uri)
    request['content-type'] = 'application/json'
    request.body = JSON.generate(payload)

    response = http.request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body.to_s)
  rescue StandardError
    nil
  end
end
