# frozen_string_literal: true

require "base64"
require "json"
require "net/http"

# Shared stubs for the OpenAI Images tests: no network, one canned PNG reply.
module ImagegenHelpers
  FakeResponse = Struct.new(:code, :body) do
    def is_a?(klass) = klass == Net::HTTPSuccess ? code == "200" : super
  end

  class FakeHttp
    attr_reader :requests

    def initialize(code = "200")
      @code = code
      @requests = []
    end

    def request(req)
      @requests << req
      FakeResponse.new(@code, JSON.generate("data" => [ { "b64_json" => Base64.strict_encode64("PNG") } ]))
    end
  end

  # Writes a small file whose content is its name, so digests differ per name.
  def write_fixture(dir, name)
    File.join(dir, name).tap { |path| File.binwrite(path, name) }
  end
end
