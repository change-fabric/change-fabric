# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative 'cf_provider_registry'

# Makes a provider's free validation request (config/providers.yml `validate`)
# before a key is stored. Only the HTTP status matters: 2xx is valid, anything
# else, a timeout, or no network at all is a failure. The key travels only in
# the request header and never appears in a returned reason.
class CfKeyValidator
  TIMEOUT = 10

  Result = Struct.new(:ok, :reason) do
    def ok? = ok
  end

  # `http` takes a Net::HTTPRequest and a URI and returns a response with
  # #code. Tests inject a stub; the default makes the real call.
  def initialize(http: method(:perform))
    @http = http
  end

  def call(provider, key)
    spec = CfProviderRegistry.fetch(provider).validate
    uri = URI(spec.fetch('url'))
    response = @http.call(request(spec, uri, key), uri)
    code = response.code.to_i
    return Result.new(true, "HTTP #{code}") if code.between?(200, 299)

    Result.new(false, "#{provider} rejected the key (HTTP #{code})")
  rescue CfProviderRegistry::UnknownProvider
    raise
  rescue StandardError => e
    Result.new(false, "could not reach #{provider} to validate the key (#{e.class})")
  end

  private

  def request(spec, uri, key)
    raise ArgumentError, "unsupported validation method #{spec['method']}" unless spec.fetch('method') == 'GET'

    req = Net::HTTP::Get.new(uri)
    case spec.fetch('auth')
    when 'bearer' then req['Authorization'] = "Bearer #{key}"
    when 'header' then req[spec.fetch('header')] = key
    else raise ArgumentError, "unsupported validation auth #{spec['auth']}"
    end
    req
  end

  def perform(req, uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |h| h.request(req) }
  end
end
