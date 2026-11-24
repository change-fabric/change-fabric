#!/usr/bin/env ruby
# frozen_string_literal: true

# A local preview of the approval console pages, for stills, a11y runs and the
# transition tests. It renders the real ConsolePages with the real response
# headers from fixtures; it is a development tool and ships nowhere.
#
#   ruby test/approval_console_preview.rb --port 0 --bind 0.0.0.0
#
# prints PREVIEW_URL=http://<host>:<port>. Routes:
#   GET  /type/<type>/state/<pending|expired|approved>
#   GET  /page/<enroll|enroll-shown|register|notice>
#   POST /type/<type>/state/<state>/approve?respond=<status>:<code>
# A page URL may end in #state=<name> (stills only): the preview injects a
# small script that stubs the passkey and drives the real page script into
# that client state. The fragment handler lives only in this file; the page
# script has no test mode.
require "json"
require "securerandom"
require "socket"
require "time"
require "uri"
require_relative "../approval_console/infra/lambda/pages"
require_relative "../scripts/approval_console/canonical"

class ApprovalConsolePreview
  Canonical = ApprovalConsole::Canonical
  TYPES = Canonical::TYPES
  FIXTURES = File.expand_path("fixtures/approval_console", __dir__)
  STATES = %w[pending expired approved].freeze
  LIFETIME = 15 * 60
  CREDENTIALS = [ "preview-credential" ].freeze

  # Client states the fragment drives, with the scripted answer each one gets.
  SCENARIOS = {
    "success" => "200:ok", "elsewhere" => "409:not_pending", "locked" => "423:locked", "code-refused" => "401:totp_invalid",
    "passkey-refused" => "401:assertion_invalid", "busy" => "503:busy", "other" => "500:boom", "cancelled" => nil,
    "waiting" => nil, "code-complete" => nil, "unsupported" => nil, "client-expired" => nil, "in-app" => nil
  }.freeze

  FRAGMENT_JS = <<~'JS'
    (()=>{
      const q=new URLSearchParams(location.search),st=(location.hash.match(/state=([\w-]+)/)||[])[1];
      const scenarios=%<scenarios>s,of=window.fetch,respond=q.get('respond')||scenarios[st];
      window.fetch=(u,o)=>of(respond?u+'?respond='+encodeURIComponent(respond):u,o);
      if(!st)return;
      const buf=()=>new ArrayBuffer(4);
      const get=st==='cancelled'?async()=>{throw new DOMException('cancelled','NotAllowedError')}:st==='waiting'?()=>new Promise(()=>{}):async()=>({rawId:buf(),response:{authenticatorData:buf(),clientDataJSON:buf(),signature:buf()}});
      Object.defineProperty(navigator,'credentials',{value:{get},configurable:true});
      if(st==='unsupported')window.PublicKeyCredential=undefined;
      if(st==='in-app')Object.defineProperty(navigator,'userAgent',{value:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/450.0]',configurable:true});
      if(st==='client-expired'){const now=Date.now;Date.now=()=>now()+17*60000}
      addEventListener('DOMContentLoaded',()=>{
        const t=document.getElementById('totp'),g=document.getElementById('go');
        if(!t||st==='unsupported'||st==='client-expired'||st==='in-app')return;
        t.value='482913';t.dispatchEvent(new Event('input'));
        if(st!=='code-complete')g.click()});
    })();
  JS

  def initialize(now: -> { Time.now.utc })
    @now = now
  end

  def fixture(type) = JSON.parse(File.read(File.join(FIXTURES, "#{type}.json")))

  # The fixture with a fresh lifetime, so a still never shows an expired page
  # by accident. Rebuilt through Canonical, the same as the real request path.
  def body_for(type)
    now = @now.call
    body = fixture(type).merge("created_at" => now.iso8601, "expires_at" => (now + LIFETIME).iso8601, "request_id" => SecureRandom.uuid)
    body["grant_expires_at"] = (now + 8 * 3600).iso8601 if type == "grant"
    Canonical.build(body)
  end

  def inject(html, nonce)
    script = %(<script nonce="#{nonce}">#{format(FRAGMENT_JS, scenarios: JSON.generate(SCENARIOS.compact))}</script>)
    html.sub(/<body[^>]*>/) { |tag| "#{tag}#{script}" }
  end

  def page(path, nonce)
    case path
    when %r{\A/type/([a-z-]+)/state/([a-z]+)\z}
      type = Regexp.last_match(1)
      state = Regexp.last_match(2)
      return unless TYPES.include?(type) && STATES.include?(state)

      string = body_for(type)
      ConsolePages.approve(nonce, string, JSON.parse(string), state, CREDENTIALS)
    when "/page/enroll" then ConsolePages.enroll(nonce, CREDENTIALS, "preview-challenge", "preview-source", false)
    when "/page/enroll-shown" then ConsolePages.enroll(nonce, [], "", "", true)
    when "/page/register" then ConsolePages.register(nonce)
    when "/page/notice" then ConsolePages.notice(nonce, "Not found", "No such request.")
    end
  end

  def index
    links = TYPES.flat_map { |type| STATES.map { |state| "/type/#{type}/state/#{state}" } } + %w[enroll enroll-shown register notice].map { |name| "/page/#{name}" }
    "<!doctype html><title>preview</title><ul>#{links.map { |link| %(<li><a href="#{link}">#{link}</a></li>) }.join}</ul>"
  end

  def approve_answer(query)
    status, code = URI.decode_www_form(query.to_s).to_h.fetch("respond", "200:ok").split(":", 2)
    payload = case status.to_i
    when 200 then { "proof" => { "kind" => "preview" } }
    when 423 then { "error" => code, "locked_until" => (@now.call + 600).iso8601 }
    else { "error" => code }
    end
    [ status.to_i, { "content-type" => "application/json", "cache-control" => "no-store" }, JSON.generate(payload) ]
  end

  # Returns [status, headers, body] for a request target such as /type/step/state/pending?respond=...
  def response(method, target)
    path, query = target.split("?", 2)
    if method == "POST" && path.end_with?("/approve")
      return approve_answer(query) if page(path.delete_suffix("/approve"), "x")

      return [ 404, { "content-type" => "text/plain" }, "not found" ]
    end
    return [ 200, { "content-type" => "text/html; charset=utf-8" }, index ] if path == "/"

    nonce = SecureRandom.base64(18)
    html = method == "GET" ? page(path, nonce) : nil
    return [ 404, { "content-type" => "text/plain" }, "not found" ] unless html

    [ 200, ConsolePages.headers(nonce), inject(html, nonce) ]
  end

  def serve(client)
    request = client.gets.to_s
    method, target, = request.split(" ")
    length = 0
    while (line = client.gets) && line != "\r\n"
      length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
    end
    client.read(length) if length.positive?
    status, headers, body = response(method, target.to_s)
    head = headers.merge("content-length" => body.bytesize.to_s, "connection" => "close").map { |k, v| "#{k}: #{v}\r\n" }.join
    client.write("HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Error'}\r\n#{head}\r\n#{body}")
  rescue StandardError => e
    warn "preview error: #{e.class}: #{e.message}"
  ensure
    client.close
  end

  def run(bind:, port:, public_host:)
    server = TCPServer.new(bind, port)
    puts "PREVIEW_URL=http://#{public_host}:#{server.addr[1]}"
    $stdout.flush
    loop { Thread.new(server.accept) { |client| serve(client) } }
  end
end

if $PROGRAM_NAME == __FILE__
  options = { port: 8080, bind: "127.0.0.1", host: nil }
  args = ARGV.dup
  until args.empty?
    case args.shift
    when "--port" then options[:port] = Integer(args.shift)
    when "--bind" then options[:bind] = args.shift
    when "--public-host" then options[:host] = args.shift
    else abort "usage: approval_console_preview.rb [--port N] [--bind ADDR] [--public-host NAME]"
    end
  end
  trap("TERM") { exit }
  ApprovalConsolePreview.new.run(bind: options[:bind], port: options[:port], public_host: options[:host] || Socket.gethostname)
end
