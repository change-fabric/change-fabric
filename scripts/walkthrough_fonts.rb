# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

# Remote web fonts for offline prototype capture. A screen may link a font
# stylesheet on an allowlisted host (Google Fonts); before capture the
# stylesheet and every font file it names are fetched with Ruby net/http and
# cached content-addressed under <root>/.cache/fonts. The screen is then
# rewritten to carry the cached bytes inline, so capture stays on --network
# none, a re-render reads the cache with no network, and the font bytes reach
# the scene's frames key through the inlined page. A fetch that fails raises
# FetchError naming the URL; there is never a silent system-font fallback.
module WalkthroughFonts
  class FetchError < StandardError; end
  class HostError < StandardError; end

  ALLOWED_HOSTS = %w[fonts.googleapis.com fonts.gstatic.com].freeze
  # Google serves woff2 only to a browser it recognizes.
  USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
  MAX_BYTES = 8 * 1024 * 1024
  TIMEOUT_S = 20
  INDEX = 'urls.json'
  FONT_MIME = { '.woff2' => 'font/woff2', '.woff' => 'font/woff', '.ttf' => 'font/ttf', '.otf' => 'font/otf' }.freeze
  URL_RE = /url\(\s*(["']?)([^"')]+)\1\s*\)/i
  LINK_RE = /<link\b[^>]*>/im
  HREF_RE = /\bhref\s*=\s*(["'])([^"']+)\1/im
  REL_RE = /\brel\s*=\s*(["'])([^"']*)\1/im
  MEDIA_RE = /\bmedia\s*=\s*(["'])([^"']*)\1/im
  IMPORT_RE = /@import\s+(["'])([^"']+)\1/i
  HINT_RELS = %w[preconnect dns-prefetch preload prefetch].freeze

  # A process-wide fetcher override (tests stub HTTP here); nil uses net/http.
  class << self
    attr_accessor :fetcher
  end

  module_function

  def absolute(url)
    url = url.strip
    url.start_with?('//') ? "https:#{url}" : url
  end

  def host(url)
    URI.parse(absolute(url)).host.to_s.downcase
  rescue URI::InvalidURIError
    ''
  end

  def allowed?(url) = ALLOWED_HOSTS.include?(host(url))

  def allowed!(url, label)
    return if allowed?(url)

    raise HostError, "#{label}: remote #{url} is not supported; only fonts from #{ALLOWED_HOSTS.join(', ')} are fetched"
  end

  def cache_dir(root) = File.join(File.expand_path(root), '.cache', 'fonts')

  # Rewrites allowlisted <link> tags: a stylesheet becomes a <style> holding
  # an @import of it (resolved later by import_css), and a preconnect or
  # preload hint is dropped, since capture never touches the network.
  def rewrite_links(html)
    html.gsub(LINK_RE) do |tag|
      href = tag[HREF_RE, 2]&.then { |h| href(h) }
      next tag unless href && remote?(href) && allowed?(href)

      rel = rels(tag)
      next '' if rel.intersect?(HINT_RELS)
      next tag unless rel.include?('stylesheet')

      media = tag[MEDIA_RE, 2].to_s.strip
      cond = media.empty? || media.casecmp('all').zero? ? '' : " #{media}"
      %(<style>@import url("#{absolute(href)}")#{cond};</style>)
    end
  end

  def remote?(value) = value.strip.match?(%r{\A(?:https?:)?//}i)

  # The CSS of an allowlisted stylesheet with each font url() swapped for a
  # data URI, so the result needs nothing from the network.
  def import_css(url, root, fetch: nil, label: 'screen')
    allowed!(url, label)
    css = read(url, root, fetch)
    css.gsub(URL_RE) do
      ref = Regexp.last_match(2)
      next Regexp.last_match(0) unless remote?(ref)

      %(url("#{font_uri(ref, root, fetch: fetch, label: url)}"))
    end
  end

  def font_uri(url, root, fetch: nil, label: 'screen')
    allowed!(url, label)
    ext = File.extname(URI.parse(absolute(url)).path).downcase
    "data:#{FONT_MIME.fetch(ext, 'application/octet-stream')};base64,#{[ read(url, root, fetch) ].pack('m0')}"
  end

  # Every remote URL a screen pulls in (link hrefs, @import, url()), from the
  # screen and every local stylesheet it reaches through links and imports.
  def remote_refs(html_path)
    dir = File.dirname(File.expand_path(html_path))
    html = File.read(html_path)
    css = local_css(html.scan(HREF_RE).map { |m| href(m.last) } + css_refs(html), dir, [])
    urls = stylesheet_links(html) + ([ html ] + css).flat_map { |c| css_refs(c) }
    urls.select { |u| remote?(u) }.map { |u| absolute(u) }.uniq
  end

  def rels(tag) = tag[REL_RE, 2].to_s.downcase.split

  def stylesheet_links(html)
    html.scan(LINK_RE).select { |tag| rels(tag).include?('stylesheet') }.filter_map { |tag| tag[HREF_RE, 2]&.then { |h| href(h) } }
  end

  # Comments are dropped first, as capture drops them, so a commented-out
  # import never adds a fetch.
  def css_refs(css)
    css = css.gsub(%r{/\*.*?\*/}m, '')
    css.scan(URL_RE).map(&:last) + css.scan(IMPORT_RE).map(&:last)
  end

  # The text of each local .css file in refs and, recursively, the local
  # stylesheets it imports; `seen` stops an import cycle.
  def local_css(refs, dir, seen)
    refs.reject { |r| remote?(r) }.flat_map do |r|
      file = r.split(/[?#]/).first.to_s
      next [] if file.empty?

      path = File.expand_path(file, dir)
      next [] unless path.end_with?('.css') && File.file?(path) && !seen.include?(path)

      seen << path
      body = File.read(path)
      [ body ] + local_css(css_refs(body), File.dirname(path), seen)
    end
  end

  # An attribute value as the browser reads it: `&amp;` in a query is `&`.
  def href(value) = CGI.unescapeHTML(value)

  # Fetches (or finds cached) every allowlisted font a screen needs, before
  # any paid step. A host off the allowlist is left to the capture check.
  def prefetch!(html_path, root, fetch: nil)
    remote_refs(html_path).select { |u| allowed?(u) }.each do |url|
      URI.parse(url).path.match?(/\.(?:woff2?|ttf|otf)\z/i) ? read(url, root, fetch) : import_css(url, root, fetch: fetch)
    end
  end

  # The bytes for a URL: from the content-addressed cache when its index
  # names a file that still matches its hash, else fetched and stored.
  def read(url, root, fetch)
    url = absolute(url)
    dir = cache_dir(root)
    sha = index(dir)[url]
    path = sha && File.join(dir, sha)
    return File.binread(path) if path && File.file?(path) && Digest::SHA256.file(path).hexdigest == sha

    body = (fetch || WalkthroughFonts.fetcher || method(:http_get)).call(url)
    store(dir, url, body)
    body
  end

  def index(dir)
    path = File.join(dir, INDEX)
    File.file?(path) ? JSON.parse(File.read(path)) : {}
  rescue JSON::ParserError
    {}
  end

  def store(dir, url, body)
    FileUtils.mkdir_p(dir)
    sha = Digest::SHA256.hexdigest(body)
    write_atomic(File.join(dir, sha), body)
    write_atomic(File.join(dir, INDEX), JSON.pretty_generate(index(dir).merge(url => sha)))
  end

  def write_atomic(path, body)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.binwrite(tmp, body)
    File.rename(tmp, path)
  end

  # The absolute target of a redirect, refused (naming the target and the
  # URL that redirected) unless it is on the allowlist too.
  def redirect_target(url, location)
    to = URI.join(url, location.to_s).to_s
    return to if allowed?(to)

    raise HostError, "font fetch refused: #{url} redirects to #{to}, and #{host(to)} is not on the font allowlist " \
                     "(#{ALLOWED_HOSTS.join(', ')})"
  end

  def http_get(url, redirects: 2)
    uri = URI.parse(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: TIMEOUT_S, read_timeout: TIMEOUT_S) do |http|
      http.request(Net::HTTP::Get.new(uri, 'User-Agent' => USER_AGENT, 'Accept' => 'text/css,*/*'))
    end
    return http_get(redirect_target(url, res['location']), redirects: redirects - 1) if res.is_a?(Net::HTTPRedirection) && redirects.positive?

    raise FetchError, "font fetch failed: #{url} returned HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    raise FetchError, "font fetch failed: #{url} is larger than #{MAX_BYTES} bytes" if res.body.to_s.bytesize > MAX_BYTES

    res.body.to_s.b
  rescue FetchError, HostError
    raise
  rescue StandardError => e
    raise FetchError, "font fetch failed: #{url}: #{e.class}: #{e.message}"
  end
end
