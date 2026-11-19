# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'

# KMS: seed encryption under a machine_id context, and receipt signing.
class ConsoleKms
  def initialize(seed_key: ENV['SEED_KEY_ID'], receipt_key: ENV['RECEIPT_KEY_ID'], client: nil)
    @seed_key = seed_key
    @receipt_key = receipt_key
    @client = client
  end

  def encrypt(plaintext, context)
    client.encrypt(key_id: @seed_key, plaintext: plaintext, encryption_context: context).ciphertext_blob
  end

  def decrypt(blob, context)
    client.decrypt(key_id: @seed_key, ciphertext_blob: blob, encryption_context: context).plaintext
  end

  # Returns [DER ECDSA signature, key arn]. The message is signed as RAW, so the
  # offline verifier's SHA-256 ECDSA check over the payload bytes matches.
  def sign(message)
    out = client.sign(key_id: @receipt_key, message: message, message_type: 'RAW', signing_algorithm: 'ECDSA_SHA_256')
    [ out.signature, @receipt_key ]
  end

  private

  def client
    @client ||= begin
      require 'aws-sdk-kms'
      Aws::KMS::Client.new
    end
  end
end

# The direct message. Best effort: a missing parameter or a failed post never
# blocks an approval, and nothing but the type, repo and short sha is sent.
class ConsoleDm
  URL = URI('https://slack.com/api/chat.postMessage')

  def initialize(token_param: ENV.fetch('DM_TOKEN_PARAM', nil), recipient_param: ENV.fetch('DM_RECIPIENT_PARAM', nil), ssm: nil)
    @token_param = token_param
    @recipient_param = recipient_param
    @ssm = ssm
  end

  def notify(text)
    return false if @token_param.to_s.empty? || @recipient_param.to_s.empty?

    post(param(@token_param), param(@recipient_param), text)
  rescue StandardError
    false
  end

  private

  def param(name)
    ssm.get_parameter(name: name, with_decryption: true).parameter.value
  end

  def ssm
    @ssm ||= begin
      require 'aws-sdk-ssm'
      Aws::SSM::Client.new
    end
  end

  def post(token, recipient, text)
    http = Net::HTTP.new(URL.host, URL.port)
    http.use_ssl = true
    http.open_timeout = 2
    http.read_timeout = 3
    request = Net::HTTP::Post.new(URL, 'content-type' => 'application/json', 'authorization' => "Bearer #{token}")
    request.body = JSON.generate(channel: recipient, text: text)
    http.request(request).is_a?(Net::HTTPSuccess)
  end
end

# A QR code as an SVG string, from the pure Ruby rqrcode_core gem vendored in
# the package. Returns nil when the gem is absent so the page still shows the
# secret string.
module ConsoleQr
  module_function

  def svg(text)
    require 'rqrcode_core'
    modules = RQRCodeCore::QRCode.new(text).modules
    size = modules.size
    cells = modules.each_with_index.flat_map do |row, y|
      row.each_with_index.filter_map { |dark, x| %(<rect x="#{x + 4}" y="#{y + 4}" width="1" height="1"/>) if dark }
    end
    %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{size + 8} #{size + 8}" shape-rendering="crispEdges">) +
      %(<rect width="100%" height="100%" fill="#fff"/><g fill="#000">#{cells.join}</g></svg>)
  rescue LoadError
    nil
  end
end
