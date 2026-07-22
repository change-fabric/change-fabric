#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'base64'

# Fetches a rendered PNG reference image from the real Figma REST API
# (`GET /v1/images/:file_key?ids=:node_id`), a two-step call: first asks Figma to
# render the node and hand back a short-lived image url, then downloads that
# url. Used by the browserless lane's Figma-alignment check to get the "what it
# should look like" reference it diffs a live screenshot against.
#
# Every failure raises FigmaError with a message specific enough to act on (no
# token configured, a Figma API error body, a bad image download) so the caller
# can surface a real, named blocker as a failing finding instead of silently
# skipping the comparison.
module ChangeFigma
  class FigmaError < StandardError; end

  module_function

  def fetch_reference_png_base64(file_key:, node_id:, token:)
    raise FigmaError, 'no Figma access token configured (see lanes.browserless.figma.token_env)' if token.to_s.empty?
    raise FigmaError, 'figma.file_key is required' if file_key.to_s.empty?
    raise FigmaError, 'figma.node_id is required' if node_id.to_s.empty?

    image_url = fetch_image_url(file_key: file_key, node_id: node_id, token: token)
    Base64.strict_encode64(download(image_url))
  end

  def fetch_image_url(file_key:, node_id:, token:)
    uri = URI("https://api.figma.com/v1/images/#{file_key}?ids=#{URI.encode_www_form_component(node_id)}&format=png")
    response = get(uri, token)
    unless response.is_a?(Net::HTTPSuccess)
      raise FigmaError, "Figma images API returned #{response.code} for #{file_key}/#{node_id}: #{response.body}"
    end

    body = JSON.parse(response.body)
    raise FigmaError, "Figma images API error for #{file_key}/#{node_id}: #{body['err']}" if body['err']

    url = body.dig('images', node_id)
    raise FigmaError, "Figma images API returned no image url for node #{node_id} (check the node id/access)" if url.to_s.empty?

    url
  rescue JSON::ParserError => e
    raise FigmaError, "Figma images API returned unparseable JSON: #{e.message}"
  end

  def download(url)
    uri = URI(url)
    response = Net::HTTP.get_response(uri)
    raise FigmaError, "failed to download rendered Figma reference image: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  def get(uri, token)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30
    request = Net::HTTP::Get.new(uri)
    request['X-Figma-Token'] = token
    http.request(request)
  end
end
