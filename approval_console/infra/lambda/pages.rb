# frozen_string_literal: true

require 'cgi'
require 'erb'
require 'json'

# The three HTML pages. Rules: no external scripts or fonts, one inline script
# and one inline style, both bound to a per-response nonce by a strict CSP, and
# no-store on every response. Every field of the approval body is rendered; the
# page never shows a hash in place of content.
module ConsolePages
  module_function

  def headers(nonce)
    {
      'content-type' => 'text/html; charset=utf-8',
      'cache-control' => 'no-store',
      'content-security-policy' => "default-src 'none'; script-src 'nonce-#{nonce}'; style-src 'nonce-#{nonce}'; " \
                                   "connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'x-content-type-options' => 'nosniff',
      'x-frame-options' => 'DENY',
      'referrer-policy' => 'no-referrer'
    }
  end

  def esc(value) = CGI.escapeHTML(value.to_s)

  # Data for the script, as JSON that cannot close the script element.
  SCRIPT_SAFE = { '<' => '\\u003c', '>' => '\\u003e', '&' => '\\u0026' }.freeze

  def data_json(hash) = JSON.generate(hash).gsub(/[<>&]/, SCRIPT_SAFE)

  def layout(nonce, title, inner, data, script)
    <<~HTML
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{esc(title)}</title>
      <style nonce="#{nonce}">
      :root{color-scheme:light dark;font-family:system-ui,sans-serif}
      body{margin:0 auto;max-width:42rem;padding:1rem 16px}
      dl{display:grid;grid-template-columns:max-content 1fr;gap:.25rem 1rem}dt{font-weight:600}dd{margin:0;overflow-wrap:anywhere}
      pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:.5rem;border:1px solid;border-radius:6px}
      input,button{font:inherit;padding:.6rem;margin:.25rem 0;min-height:44px}button{min-width:44px}
      #msg{font-weight:600}img{max-width:16rem;width:100%;background:#fff}
      </style></head><body>
      <h1>#{esc(title)}</h1>
      #{inner}
      <p id="msg" role="status"></p>
      <script type="application/json" id="d" nonce="#{nonce}">#{data}</script>
      <script nonce="#{nonce}">#{script}</script>
      </body></html>
    HTML
  end

  COMMON_JS = <<~JS
    const d=JSON.parse(document.getElementById('d').textContent),enc=new TextEncoder(),msg=document.getElementById('msg');
    const b64u=b=>btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
    const unb64u=s=>Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
    const sha=async t=>crypto.subtle.digest('SHA-256',enc.encode(t));
    const post=async(path,obj)=>{const r=await fetch(path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(obj)});return [r.status,await r.json().catch(()=>({}))]};
    const assertion=async(source)=>{const c=await navigator.credentials.get({publicKey:{challenge:await sha(source),rpId:location.hostname,userVerification:'required',timeout:60000,allowCredentials:d.credentials.map(id=>({type:'public-key',id:unb64u(id)}))}});const r=c.response;return {credential_id:b64u(c.rawId),authenticator_data:b64u(r.authenticatorData),client_data_json:b64u(r.clientDataJSON),signature:b64u(r.signature)}};
    const fail=e=>{msg.textContent='Failed: '+(e&&e.message?e.message:e)};
  JS

  def body_rows(body)
    body.map do |key, value|
      "<dt>#{esc(key)}</dt><dd>#{value_html(key, value)}</dd>"
    end.join
  end

  def value_html(key, value)
    return esc(value) if value.is_a?(String)
    return "<ul>#{value.map { |file| "<li><code>#{esc(file)}</code></li>" }.join}</ul>" if key == 'files' && value.is_a?(Array) && value.all?(String)

    "<pre>#{esc(JSON.pretty_generate(value))}</pre>"
  end

  GITHUB = 'github.com'
  REPO_ID = %r{\Arepo:#{Regexp.escape(GITHUB)}/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)\z}
  PR_PATH = %r{\Ahttps://#{Regexp.escape(GITHUB)}/([^/\s]+)/([^/\s]+)/pull/(\d+)/?\z}

  # Tap-through GitHub links built only from signed fields (repo, sha, tag,
  # pr_url), never from agent text: the host is the constant above, the repo
  # comes from the signed repo id, the commit and tag are percent-encoded, and
  # a pr_url is linked only when it names that same repo. Anything that does
  # not fit the pattern yields no link rather than a guessed one.
  def links(body)
    owner, name = REPO_ID.match(body['repo'].to_s)&.captures
    return [] unless owner

    root = "https://#{GITHUB}/#{owner}/#{name}"
    list = []
    list << [ 'Commit on GitHub', "#{root}/commit/#{ERB::Util.url_encode(body['sha'].to_s)}" ] if body['sha'].to_s.match?(/\A[0-9a-f]{40}\z/)
    list << [ 'Release tag on GitHub', "#{root}/releases/tag/#{ERB::Util.url_encode(body['tag'])}" ] if body['type'] == 'release' && body['tag'].is_a?(String)
    pr = PR_PATH.match(body['pr_url'].to_s)
    list << [ 'Pull request on GitHub', "#{root}/pull/#{pr[3]}" ] if pr && [ pr[1], pr[2] ] == [ owner, name ]
    list
  end

  def links_html(body)
    items = links(body).map { |label, url| "<li><a href=\"#{esc(url)}\" rel=\"noopener noreferrer\">#{esc(label)}</a></li>" }
    items.empty? ? '' : "<ul>#{items.join}</ul>"
  end

  def approve(nonce, body_string, body, status, credentials)
    inner = +"<p>Review every field. The passkey signs a hash of exactly this text.</p>#{links_html(body)}<dl>#{body_rows(body)}</dl>"
    if status == 'pending'
      inner << '<label for="totp">Code from your TOTP app</label><br>' \
               '<input id="totp" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}">' \
               '<br><button id="go" type="button">Approve with passkey</button>'
    else
      inner << "<p>This request is #{esc(status)}.</p>"
    end
    script = COMMON_JS + <<~JS
      const go=document.getElementById('go');
      if(go)go.onclick=async()=>{go.disabled=true;try{msg.textContent='Waiting for passkey...';const a=await assertion(d.body);a.totp=document.getElementById('totp').value;const [s,j]=await post(location.pathname+'/approve',a);msg.textContent=s===200?'Approved. You can close this page.':'Refused ('+s+'): '+(j.error||'error');if(s!==200)go.disabled=false}catch(e){fail(e);go.disabled=false}};
    JS
    layout(nonce, "Approve #{body['type']}", inner, data_json(body: body_string, credentials: credentials), script)
  end

  def enroll(nonce, credentials, challenge_id, source, already_shown)
    inner = if already_shown
              '<p>The secret was already shown once and cannot be shown again.</p>'
    else
              '<p>Shown once, after a passkey check. Add it to any RFC 6238 TOTP app, one entry per machine.</p>' \
              '<button id="go" type="button">Show secret</button><div id="out" hidden>' \
              '<p><code id="secret"></code> <button id="c1" type="button">Copy secret</button></p>' \
              '<p><code id="uri"></code> <button id="c2" type="button">Copy URI</button></p><img id="qr" alt="QR code for the secret"></div>'
    end
    script = COMMON_JS + <<~JS
      const go=document.getElementById('go');
      if(go)go.onclick=async()=>{go.disabled=true;try{const a=await assertion(d.source);a.challenge_id=d.challenge_id;const [s,j]=await post(location.pathname,a);if(s!==200){msg.textContent='Refused ('+s+'): '+(j.error||'error');return}
      document.getElementById('secret').textContent=j.secret;document.getElementById('uri').textContent=j.uri;if(j.qr_svg_b64)document.getElementById('qr').src='data:image/svg+xml;base64,'+j.qr_svg_b64;document.getElementById('out').hidden=false;go.hidden=true;
      document.getElementById('c1').onclick=()=>navigator.clipboard.writeText(j.secret);document.getElementById('c2').onclick=()=>navigator.clipboard.writeText(j.uri)}catch(e){fail(e);go.disabled=false}};
    JS
    layout(nonce, 'Enroll the TOTP secret', inner, data_json(credentials: credentials, challenge_id: challenge_id, source: source), script)
  end

  def register(nonce)
    inner = '<p>Register this device passkey. Paste the one-time token the enroll command showed in your terminal.</p>' \
            '<input id="token" autocomplete="off" aria-label="One-time token"><br>' \
            '<input id="label" placeholder="Label (optional)" aria-label="Label"><br><button id="go" type="button">Register passkey</button>'
    script = COMMON_JS + <<~JS
      const go=document.getElementById('go');
      go.onclick=async()=>{go.disabled=true;try{const token=document.getElementById('token').value.trim();
      const body={token};let [s,o]=await post('/register/options',body);
      if(s===401&&o.error==='assertion_required'){d.credentials=o.credentials;body.assertion=await assertion('cf-add-credential:'+o.token_hash);[s,o]=await post('/register/options',body)}
      if(s!==200){msg.textContent='Refused ('+s+'): '+(o.error||'error');go.disabled=false;return}
      const pk=o.publicKey;pk.challenge=unb64u(pk.challenge);pk.user.id=unb64u(pk.user.id);pk.excludeCredentials=(pk.excludeCredentials||[]).map(c=>({type:'public-key',id:unb64u(c.id)}));
      const c=await navigator.credentials.create({publicKey:pk});
      const [s3,j]=await post('/register/verify',{token,label:document.getElementById('label').value,id:c.id,client_data_json:b64u(c.response.clientDataJSON),attestation_object:b64u(c.response.attestationObject)});
      msg.textContent=s3===200?'Registered. Return to your terminal.':'Refused ('+s3+'): '+(j.error||'error')}catch(e){fail(e);go.disabled=false}};
    JS
    layout(nonce, 'Register a passkey', inner, data_json(credentials: []), script)
  end

  def notice(nonce, title, text) = layout(nonce, title, "<p>#{esc(text)}</p>", data_json({}), '')
end
