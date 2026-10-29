# frozen_string_literal: true

# Parses a literal Figma URL into its file key, optional node id, and optional
# branch key. Pure; no network.
module FigmaUrl
  Parsed = Data.define(:file_key, :node_id, :branch_key, :kind)
  PATH = %r{\Ahttps://(?:www\.)?figma\.com/(design|file|make|board|slides)/([A-Za-z0-9]+)(?:/branch/([A-Za-z0-9]+))?(?:/[^?#]*)?}

  def self.parse(url)
    m = PATH.match(url.to_s.strip) or return nil
    node = url[/[?&]node-id=([^&#]+)/, 1]&.tr('-', ':')
    Parsed.new(file_key: m[3] || m[2], node_id: node, branch_key: m[3], kind: m[1])
  end
end

if $PROGRAM_NAME == __FILE__
  require 'json'
  parsed = FigmaUrl.parse(ARGV.first)
  unless parsed
    warn 'usage: figma_url.rb <figma-url> (not a recognized Figma URL)'
    exit 1
  end
  puts JSON.generate(parsed.to_h)
end
