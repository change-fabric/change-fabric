# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'
require_relative 'canonical'

module ApprovalConsole
  # The machine side of the console's signed routes. Every call carries
  # x-cf-timestamp and x-cf-signature: this machine's P-256 signature over
  # method, path, SHA-256(body) and the timestamp, which the console checks
  # against the public key in M#<id>/META.
  #
  # `transport` is a callable (method, url, headers, body) -> [status, body],
  # injected by tests to drive the console app in process. A network failure,
  # a timeout or a 5xx raises Unreachable, which callers treat as "console
  # down"; any other non-2xx raises Refused with the console's error code.
  class Client
    class Unreachable < StandardError; end

    class Refused < StandardError
      attr_reader :status, :code, :data

      def initialize(status, data)
        @status = status
        @data = data.is_a?(Hash) ? data : {}
        @code = @data['error'].to_s
        super("console refused (#{status}): #{@code.empty? ? 'error' : @code}")
      end
    end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 12
    NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError ].freeze

    # nil unless the store has a console URL and a machine key.
    def self.for(store, transport: nil, clock: -> { Time.now })
      key = store.console_configured? && store.machine_key
      return nil unless key

      new(base_url: store.base_url, machine_id: store.machine_id, key: key, transport: transport, clock: clock)
    end

    def initialize(base_url:, machine_id:, key:, transport: nil, clock: -> { Time.now })
      @base = URI(base_url.to_s)
      @machine_id = machine_id
      @key = key
      @transport = transport || method(:http)
      @clock = clock
    end

    def create_request(body) = call('POST', machine_path('/requests'), 'body' => body)

    # Marks a run-script receipt consumed on the console (single use). Raises
    # Refused 409 when it was already consumed and 410 when it has expired.
    def consume(request_id) = call('POST', machine_path("/r/#{request_id}/consume"), {})

    def proof(request_id) = call('GET', machine_path("/r/#{request_id}/proof"), nil)

    def terminal_approve(body, code) = call('POST', machine_path('/terminal-approve'), 'body' => body, 'code' => code)

    def sync(body, step, code) = call('POST', machine_path('/sync'), 'body' => body, 'step' => step, 'code' => code)

    private

    def machine_path(suffix) = "/m/#{@machine_id}#{suffix}"

    def call(method, path, payload)
      raw = payload.nil? ? '' : JSON.generate(payload)
      raise Refused.new(413, 'error' => 'too_large') if raw.bytesize > Canonical::MAX_REQUEST_BYTES

      status, text = @transport.call(method, "#{origin}#{path}", headers(method, path, raw), raw)
      data = parse(text)
      raise Unreachable, "console returned #{status}" if status.to_i >= 500
      raise Refused.new(status.to_i, data) unless status.to_i.between?(200, 299)

      data
    rescue *NETWORK_ERRORS => e
      raise Unreachable, e.message
    end

    def origin = "#{@base.scheme}://#{@base.host}#{@base.port == @base.default_port ? '' : ":#{@base.port}"}"

    def headers(method, path, raw)
      stamp = @clock.call.to_i.to_s
      message = [ method, path, Digest::SHA256.hexdigest(raw.b), stamp ].join("\n")
      signature = Base64.urlsafe_encode64(@key.sign('SHA256', message), padding: false)
      { 'content-type' => 'application/json', 'x-cf-timestamp' => stamp, 'x-cf-signature' => signature }
    end

    def parse(text)
      data = JSON.parse(text.to_s)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def http(method, url, headers, body)
      uri = URI(url)
      if method == 'GET'
        request = Net::HTTP::Get.new(uri)
      else
        request = Net::HTTP::Post.new(uri)
        request.body = body
      end
      headers.each { |name, value| request[name] = value }
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) { |conn| conn.request(request) }
      [ response.code.to_i, response.body ]
    end
  end
end
