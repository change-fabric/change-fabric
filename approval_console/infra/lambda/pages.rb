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


  # The site's four authored colors and their derived tokens, copied by value
  # from site/src/styles.css (a test holds them equal), plus the one console
  # token, --danger, with a value per color scheme (site/DESIGN.md records it).
  CSS = <<~'CSS'
    :root {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --sage: #9ea39b;
      --danger: #b0182c;
      --bg: var(--cream);
      --surface: color-mix(in srgb, var(--plum) 3%, var(--cream));
      --code-bg: color-mix(in srgb, var(--plum) 5%, var(--cream));
      --border: color-mix(in srgb, var(--sage) 60%, var(--cream));
      --border-strong: color-mix(in srgb, var(--sage) 85%, var(--cream));
      --text: var(--plum);
      --muted: color-mix(in srgb, var(--sage) 42%, var(--plum));
      --accent: color-mix(in srgb, var(--lilac) 62%, var(--plum));
      --btn: var(--accent);
      --btn-text: var(--cream);
      --bar-h: 9rem;
      color-scheme: light;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --danger: #ff9b9b;
        --bg: var(--plum);
        --surface: color-mix(in srgb, var(--cream) 4%, var(--plum));
        --code-bg: color-mix(in srgb, var(--cream) 6%, var(--plum));
        --border: color-mix(in srgb, var(--sage) 30%, var(--plum));
        --border-strong: color-mix(in srgb, var(--sage) 50%, var(--plum));
        --text: var(--cream);
        --muted: color-mix(in srgb, var(--sage) 70%, var(--cream));
        --accent: color-mix(in srgb, var(--lilac) 75%, var(--cream));
        --btn-text: var(--plum);
        color-scheme: dark;
      }
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 1rem/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
    }
    .page { max-width: 40rem; margin: 0 auto; padding: 1.25rem 1rem 3rem; }
    code, pre, .mono, input.code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.9em;
    }
    .brand { margin: 0 0 1.25rem; font-size: 0.8125rem; color: var(--muted); letter-spacing: 0.02em; }
    h1 { margin: 0.25rem 0 0.5rem; font: 600 1.75rem/1.2 ui-serif, Georgia, serif; }
    .hl-danger { padding-bottom: 0.75rem; border-bottom: 2px solid var(--danger); }
    .meta { display: flex; flex-wrap: wrap; gap: 0.25rem 1rem; align-items: center; margin: 0.75rem 0 1rem; }
    .risk { display: inline-flex; align-items: center; gap: 0.375rem; font-size: 0.875rem; font-weight: 700; }
    .risk svg { width: 1.125rem; height: 1.125rem; flex: none; }
    .risk.high { color: var(--danger); }
    .risk-note { margin: -0.25rem 0 1rem; font-size: 0.9375rem; }
    .countdown { margin: 0; font-size: 0.875rem; color: var(--muted); }
    .changes {
      margin: 0 0 1rem; padding: 0.875rem 0;
      border-top: 1px solid var(--border-strong); border-bottom: 1px solid var(--border-strong);
      font-size: 1.1875rem; line-height: 1.45; font-weight: 500; overflow-wrap: anywhere;
    }
    .links { display: flex; flex-wrap: wrap; gap: 0.25rem 1.25rem; margin: 0 0 1.5rem; padding: 0; list-style: none; }
    .links a { display: inline-block; min-height: 2.75rem; line-height: 2.75rem; color: var(--accent); font-weight: 600; text-decoration: underline; text-underline-offset: 0.2em; }
    .status { display: flex; gap: 0.75rem; align-items: flex-start; margin: 0 0 1.25rem; padding: 0.875rem 0; border-top: 2px solid var(--text); border-bottom: 1px solid var(--border-strong); }
    .status[hidden] { display: none; }
    .status svg { width: 1.75rem; height: 1.75rem; flex: none; }
    .status[data-kind="ok"] .ic-info, .status:not([data-kind="ok"]) .ic-ok { display: none; }
    .status p { margin: 0; }
    .status .big { font: 600 1.375rem/1.25 ui-serif, Georgia, serif; }
    .status .sub { font-size: 0.9375rem; color: var(--muted); }
    section { margin: 0 0 1.5rem; }
    h2 { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
    .zone-note { margin: 0 0 0.75rem; font-size: 0.875rem; color: var(--muted); }
    dl { display: grid; align-items: baseline; grid-template-columns: 6.5rem minmax(0, 1fr); gap: 0.625rem 0.75rem; margin: 0; }
    dt { font-size: 0.875rem; color: var(--muted); overflow-wrap: anywhere; }
    dd { margin: 0; overflow-wrap: anywhere; }
    dd ul { margin: 0; padding: 0; list-style: none; }
    [data-field] { white-space: pre-wrap; }
    dd li + li { margin-top: 0.125rem; }
    dl.sub { grid-template-columns: minmax(0, 8rem) minmax(0, 1fr); gap: 0.375rem 0.75rem; }
    .was { display: block; font-size: 0.8125rem; color: var(--muted); }
    [data-zone="verified"] { border-top: 1px solid var(--border-strong); padding-top: 0.75rem; }
    [data-zone="agent"] { border: 1px solid var(--border-strong); background: var(--surface); padding: 0.875rem; }
    [data-zone="agent"] h2 { color: var(--text); display: flex; gap: 0.375rem; align-items: center; }
    [data-zone="agent"] h2 svg { width: 1rem; height: 1rem; flex: none; }
    [data-zone="agent"] q { quotes: "\201C" "\201D"; }
    details { margin: 0 0 0.5rem; }
    summary { display: flex; align-items: center; min-height: 2.75rem; cursor: pointer; font-weight: 600; color: var(--accent); }
    details.more { margin: 0.25rem 0 0; }
    details.more summary { font-size: 0.875rem; }
    details.more q { display: block; white-space: pre-wrap; }
    .hint { margin: 0 0 0.75rem; padding: 0.625rem 0.75rem; border: 1px solid var(--border-strong); font-size: 0.9375rem; font-weight: 600; }
    .hint[hidden] { display: none; }
    details.sec { border-top: 1px solid var(--border); margin: 0; }
    details.sec summary { color: var(--text); }
    pre { margin: 0; padding: 0.75rem; background: var(--code-bg); overflow-x: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
    .approve-info { margin: 0 0 0.75rem; }
    .approve-info p { margin: 0; }
    .approve-info .lead { font-weight: 600; }
    .muted { color: var(--muted); font-size: 0.9375rem; }
    form#approve { margin: 0 0 1.5rem; }
    form#approve .recap { display: none; }
    #msg { margin: 0 0 0.5rem; font-size: 0.9375rem; font-weight: 600; }
    #msg:empty { display: none; }
    .row { display: flex; gap: 0.625rem; align-items: flex-end; }
    .vis-label { display: block; margin: 0 0 0.25rem; font-size: 0.8125rem; color: var(--muted); }
    .field { flex: none; }
    input.code {
      width: 9.5rem; min-height: 3rem; padding: 0 0.25rem;
      font-size: 1.125rem; letter-spacing: 0.12em; text-align: center;
      color: var(--text); background: var(--bg);
      border: 1px solid var(--border-strong); border-radius: 0.375rem;
    }
    input.text { width: 100%; min-height: 2.75rem; margin: 0 0 0.75rem; padding: 0 0.625rem; font: inherit; color: var(--text); background: var(--bg); border: 1px solid var(--border-strong); border-radius: 0.375rem; }
    button { font: 600 1rem system-ui, -apple-system, sans-serif; min-height: 2.75rem; min-width: 2.75rem; padding: 0 1rem; color: var(--btn-text); background: var(--btn); border: 0; border-radius: 0.375rem; }
    button.quiet { color: var(--text); background: transparent; border: 1px solid var(--border-strong); }
    button#go { flex: 1; white-space: nowrap; min-height: 3rem; }
    button:disabled { background: transparent; color: var(--muted); border: 1px solid var(--border-strong); }
    img { max-width: 16rem; width: 100%; background: #fff; }
    .noscript { margin: 0; padding: 0.75rem; border: 1px solid var(--border-strong); font-size: 0.9375rem; }
    @media (max-width: 39.99rem) {
      body.has-bar { padding-bottom: calc(var(--bar-h) + env(safe-area-inset-bottom)); }
      form#approve {
        position: fixed; left: 0; right: 0; bottom: 0; margin: 0;
        padding: 0.625rem 1rem calc(0.625rem + env(safe-area-inset-bottom));
        background: var(--bg); border-top: 1px solid var(--border-strong);
      }
      form#approve .recap { display: flex; flex-wrap: nowrap; min-width: 0; gap: 0 0.375rem; align-items: center; margin: 0 0 0.375rem; font-size: 0.8125rem; }
      form#approve.has-msg .recap { display: none; }
      form#approve .recap > span:last-child { color: var(--muted); min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      form#approve .recap .risk { flex: none; white-space: nowrap; font-size: 0.8125rem; }
      form#approve .recap .risk svg { width: 1rem; height: 1rem; }
      input.code { width: 7.25rem; }
    }
    @media (min-width: 40rem) {
      .page { padding-top: 2.5rem; }
      h1 { font-size: 2rem; }
      input.code { width: 11rem; }
      button#go { flex: none; min-width: 14rem; }
    }
  CSS

  def icon(name, cls = nil)
    paths = {
      high: '<path d="M10 2.5 18.5 17h-17z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M10 8v4.2M10 14.4v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      elevated: '<path d="M10 2 18 10 10 18 2 10z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M10 6.8v4M10 13v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      standard: '<circle cx="10" cy="10" r="8" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="m6.2 10.2 2.6 2.6 5-5.4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
      info: '<circle cx="10" cy="10" r="8" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M10 9v5M10 6.2v.1" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
      quote: '<path d="M3 4h14v9H9l-4 3.5V13H3z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>'
    }
    klass = cls ? %( class="#{cls}") : ''
    %(<svg viewBox="0 0 20 20" aria-hidden="true" focusable="false"#{klass}>#{paths.fetch(name)}</svg>)
  end

  def layout(nonce, title, inner, data, script, body_class: nil)
    klass = body_class ? %( class="#{body_class}") : ''
    <<~HTML
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <meta name="color-scheme" content="light dark">
      <title>#{esc(title)}</title>
      <style nonce="#{nonce}">
      #{CSS}</style></head><body#{klass}>
      <main class="page">
      <p class="brand">change-fabric approvals</p>
      #{inner}
      </main>
      <script type="application/json" id="d" nonce="#{nonce}">#{data}</script>
      <script nonce="#{nonce}">#{script}</script>
      </body></html>
    HTML
  end

  MSG = '<p id="msg" role="status"></p>'

  COMMON_JS = <<~JS
    const d=JSON.parse(document.getElementById('d').textContent),enc=new TextEncoder(),msg=document.getElementById('msg');
    const b64u=b=>btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
    const unb64u=s=>Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0));
    const sha=async t=>crypto.subtle.digest('SHA-256',enc.encode(t));
    const post=async(path,obj)=>{const r=await fetch(path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(obj)});return [r.status,await r.json().catch(()=>({}))]};
    const assertion=async(source)=>{const c=await navigator.credentials.get({publicKey:{challenge:await sha(source),rpId:location.hostname,userVerification:'required',timeout:60000,allowCredentials:d.credentials.map(id=>({type:'public-key',id:unb64u(id)}))}});const r=c.response;return {credential_id:b64u(c.rawId),authenticator_data:b64u(r.authenticatorData),client_data_json:b64u(r.clientDataJSON),signature:b64u(r.signature)}};
    const fail=e=>{msg.textContent='Failed: '+(e&&e.message?e.message:e)};
  JS

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
    items.empty? ? '' : "<ul class=\"links\">#{items.join}</ul>"
  end


  TYPE_TITLES = {
    'step' => 'Approve a gated step', 'override' => 'Override a merge or tag gate', 'prod-op' => 'Run a production operation',
    'money' => 'Spend money', 'carve-out' => 'Merge a carve-out PR', 'release' => 'Publish a release'
  }.freeze
  DEFAULT_TITLE = 'Approve a request'
  # Risk comes from the signed type only, never from agent text or argv.
  RISK = { 'step' => :standard, 'override' => :high, 'prod-op' => :high, 'money' => :high, 'carve-out' => :elevated, 'release' => :elevated }.freeze
  RISK_WORDS = { standard: 'Standard', high: 'High risk', elevated: 'Elevated risk' }.freeze
  CONSEQUENCE = {
    'override' => 'Lifts a safety guard for this commit.',
    'prod-op' => 'Runs against production. The console shows the command, not what it will change.',
    'money' => 'Spends real money. The console shows the command, not the cost.',
    'carve-out' => 'Skips the normal review gates for this merge.',
    'release' => 'Publishes a release that others can install.'
  }.freeze

  HIDDEN = /[​-‏‪-‮⁦-⁩﻿]/

  # Shows each bidi and zero-width code point as a visible [U+XXXX] marker so
  # nothing invisible can reorder displayed text. Raw code points stay only in
  # the data island.
  def neutral(text) = text.to_s.gsub(HIDDEN) { |char| format('[U+%04X]', char.ord) }

  def txt(value) = esc(neutral(value))

  def shown(path, value)
    return "format v#{value}" if path == [ 'v' ]

    value.nil? ? 'none' : value.to_s
  end

  def leaves(value, path = [])
    case value
    when Hash then value.empty? ? [ [ path, value ] ] : value.flat_map { |key, item| leaves(item, path + [ key ]) }
    when Array then value.empty? ? [ [ path, value ] ] : value.each_with_index.flat_map { |item, index| leaves(item, path + [ index ]) }
    else [ [ path, value ] ]
    end
  end

  VERIFIED_KEYS = %w[repo sha type created_at expires_at].freeze
  TECHNICAL_KEYS = %w[machine_id request_id profile v pr_url].freeze
  TYPED_VERIFIED = {
    'override' => %w[scope], 'prod-op' => %w[argv], 'money' => %w[argv], 'carve-out' => %w[base files], 'release' => %w[tag commit]
  }.freeze
  VERIFIED_ORDER = %w[repo sha tag commit base scope items argv type created_at expires_at files].freeze
  AGENT_ORDER = %w[pr_title summary reason items].freeze
  LABELS = {
    'repo' => 'Repo', 'sha' => 'Commit', 'tag' => 'Tag', 'commit' => 'Release commit', 'base' => 'Base', 'scope' => 'Scope',
    'type' => 'Type', 'created_at' => 'Created', 'expires_at' => 'Expires', 'pr_title' => 'PR title', 'summary' => 'Summary',
    'reason' => 'Reason'
  }.freeze

  # The zone that holds a body leaf. Anything not named as signed and
  # machine-derived falls to the agent zone, so a surprise field is never
  # shown as verified.
  def zone(type, path)
    top = path.first
    return :technical if TECHNICAL_KEYS.include?(top)
    return :verified if VERIFIED_KEYS.include?(top) || TYPED_VERIFIED.fetch(type, []).include?(top)
    return :agent unless type == 'step' && top == 'items'

    %w[step digest base_fields].include?(path[2]) ? :verified : :agent
  end

  def attr(path) = txt(path.join('.'))

  LONG_TEXT = 600

  def leaf(path, value, tag)
    extra = tag == 'time' ? %( datetime="#{txt(value)}") : ''
    text = shown(path, value)
    return %(<#{tag} data-field="#{attr(path)}"#{extra}>#{txt(text)}</#{tag}>) unless tag == 'q' && text.length > LONG_TEXT

    # A long agent leaf shows its first LONG_TEXT characters; the rest stays in
    # the DOM inside a details element, cut before neutralizing so a marker is
    # never split.
    rest = text[LONG_TEXT..]
    %(<q data-field="#{attr(path)}">#{txt(text[0, LONG_TEXT])}</q>) +
      %(<details class="more" data-rest="#{attr(path)}"><summary>Show the rest (#{rest.length} more characters)</summary><q>#{txt(rest)}</q></details>)
  end

  def dig_current(current, rel)
    current.dig(*rel)
  rescue TypeError, NoMethodError
    nil
  end

  # A nested value as sub-rows, one per leaf. `current` (a hash of the signed
  # base values) adds a "Current:" line under each proposed value.
  def nested(path, value, tag, current: nil)
    return leaf(path, value, tag) unless (value.is_a?(Hash) || value.is_a?(Array)) && !value.empty?

    rows = leaves(value).map do |rel, item|
      was = current.is_a?(Hash) ? %(<span class="was">Current: #{txt(shown([], dig_current(current, rel) || 'not set'))}</span>) : ''
      "<dt>#{txt(rel.join('.'))}</dt><dd>#{leaf(path + rel, item, tag)}#{was}</dd>"
    end
    %(<dl class="sub">#{rows.join}</dl>)
  end

  def row(label, inner) = "<dt>#{txt(label)}</dt><dd>#{inner}</dd>"

  def file_items(files, offset) = "<ul>#{files.each_with_index.map { |file, i| "<li>#{leaf([ 'files', offset + i ], file, 'code')}</li>" }.join}</ul>"

  def files_block(files)
    return nested([ 'files' ], files, 'code') unless files.is_a?(Array) && !files.empty? && files.all?(String)

    rest = files.drop(8)
    more = rest.empty? ? '' : "<details><summary>Show #{rest.size} more files</summary>#{file_items(rest, 8)}</details>"
    %(<p class="muted">#{files.size} #{files.size == 1 ? 'file' : 'files'} changed</p>#{file_items(files.first(8), 0)}#{more})
  end

  def argv_block(argv)
    return nested([ 'argv' ], argv, 'code') unless argv.is_a?(Array) && !argv.empty? && argv.all?(String)

    %(<ul class="mono">#{argv.each_with_index.map { |token, i| "<li>#{leaf([ 'argv', i ], token, 'code')}</li>" }.join}</ul>)
  end

  def step_verified_rows(items)
    items.each_with_index.flat_map do |item, i|
      next [] unless item.is_a?(Hash)

      suffix = items.size > 1 ? " #{i + 1}" : ''
      path = [ 'items', i ]
      rows = []
      rows << row("Step#{suffix}", leaf(path + [ 'step' ], item['step'], 'code')) if item.key?('step')
      rows << row("Digest#{suffix}", leaf(path + [ 'digest' ], item['digest'], 'code')) if item.key?('digest')
      rows << row("Current values#{suffix}", nested(path + [ 'base_fields' ], item['base_fields'], 'code')) if item.key?('base_fields')
      rows
    end
  end

  def step_agent_rows(items)
    items.each_with_index.flat_map do |item, i|
      path = [ 'items', i ]
      next [ row("Item #{i + 1}", leaf(path, item, 'q')) ] unless item.is_a?(Hash)

      suffix = items.size > 1 ? " (step #{i + 1})" : ''
      item.filter_map do |key, value|
        next if %w[step digest base_fields].include?(key)

        label = key == 'fields' ? "Proposed values, written by the agent#{suffix}" : key
        row(label, nested(path + [ key ], value, 'q', current: key == 'fields' ? item['base_fields'] : nil))
      end
    end
  end

  def verified_rows(body)
    type = body['type']
    keys = VERIFIED_ORDER.select { |key| body.key?(key) && (zone(type, [ key ]) == :verified || (type == 'step' && key == 'items')) }
    rows = keys.flat_map do |key|
      value = body[key]
      case key
      when 'files' then [ row('Files', files_block(value)) ]
      when 'argv' then [ row('Command', argv_block(value)) ]
      when 'items' then value.is_a?(Array) ? step_verified_rows(value) : []
      else [ row(LABELS.fetch(key), nested([ key ], value, key.end_with?('_at') ? 'time' : 'code')) ]
      end
    end
    rows << row('Scope', 'merge and tag guards') if type == 'override' && !body.key?('scope')
    rows.join
  end

  def agent_rows(body)
    type = body['type']
    keys = body.keys.select { |key| zone(type, [ key ]) == :agent || (type == 'step' && key == 'items') }
    keys = keys.sort_by { |key| [ AGENT_ORDER.index(key) || AGENT_ORDER.size, key ] }
    rows = keys.flat_map do |key|
      value = body[key]
      next step_agent_rows(value) if type == 'step' && key == 'items' && value.is_a?(Array)

      [ row(LABELS.fetch(key, key), nested([ key ], value, 'q')) ]
    end
    rows.empty? ? '<p class="muted">No agent text for this request.</p>' : "<dl>#{rows.join}</dl>"
  end

  def technical_rows(body)
    rows = TECHNICAL_KEYS.select { |key| body.key?(key) }.map { |key| row(key, nested([ key ], body[key], 'code')) }
    rows << row('type (raw, echo)', "<code>#{txt(body['type'])}</code>")
    rows << row('created_at (raw, echo)', "<code>#{txt(body['created_at'])}</code>")
    rows.join
  end

  def repo_name(body)
    owner, name = REPO_ID.match(body['repo'].to_s)&.captures
    owner ? "#{owner}/#{name}" : body['repo'].to_s
  end

  def pr_number(body)
    owner, name = REPO_ID.match(body['repo'].to_s)&.captures
    pr = PR_PATH.match(body['pr_url'].to_s)
    pr[3] if owner && pr && [ pr[1], pr[2] ] == [ owner, name ]
  end

  def command_text(body, limit)
    argv = body['argv'].is_a?(Array) ? body['argv'].map(&:to_s) : []
    text = argv.join(' ')
    text.length > limit ? "#{text[0, limit]}..." : text
  end

  def step_names(body)
    names = Array(body['items']).map { |item| item.is_a?(Hash) ? item['step'].to_s : '' }
    shown_names = []
    names.each { |name| shown_names << name if shown_names.empty? || (shown_names + [ name ]).join(', ').length <= 60 }
    rest = names.size - shown_names.size
    rest.positive? ? "#{shown_names.join(', ')} and #{rest} more" : shown_names.join(', ')
  end

  def plural(count, word) = "#{count} #{count == 1 ? word : "#{word}s"}"

  # One plain-text sentence built from signed, non-agent fields only.
  def what_changes(body)
    repo = repo_name(body)
    sha7 = body['sha'].to_s[0, 7]
    case body['type']
    when 'step' then "Approve #{plural(Array(body['items']).size, 'step')} in #{repo} at #{sha7}: #{step_names(body)}"
    when 'override' then "Override the #{body['scope'] ? "#{body['scope']} guard" : 'merge and tag guards'} for #{repo} at #{sha7}"
    when 'prod-op' then "Run in production: #{command_text(body, 80)} (#{repo} at #{sha7})"
    when 'money' then "Spend via: #{command_text(body, 80)} (#{repo} at #{sha7})"
    when 'carve-out' then "Merge #{pr_number(body) ? "PR ##{pr_number(body)}" : 'a PR'} into #{body['base']} at #{sha7} (#{plural(Array(body['files']).size, 'file')})"
    when 'release' then "Publish #{body['tag']} at #{body['commit'].to_s[0, 7]}"
    else "Approve a #{body['type']} request at #{sha7}"
    end
  end

  def recap_text(body)
    sha7 = body['sha'].to_s[0, 7]
    case body['type']
    when 'step' then "Step · #{Array(body['items']).size} · #{sha7}"
    when 'override' then "Override · #{body['scope'] || 'merge+tag'} · #{sha7}"
    when 'prod-op', 'money' then command_text(body, 200)
    when 'carve-out' then "Carve-out · PR ##{pr_number(body) || '?'} · #{sha7}"
    when 'release' then "Release · #{body['tag']}"
    else "Request · #{sha7}"
    end
  end

  def risk_span(risk)
    %(<span class="risk#{risk == :high ? ' high' : ''}">#{icon(risk)}<span>#{RISK_WORDS.fetch(risk)}</span></span>)
  end

  def result_block(kind, big, sub, hidden: false)
    %(<div id="result" class="status" role="status" data-kind="#{kind}"#{hidden ? ' hidden' : ''}>#{icon(:standard, 'ic-ok')}#{icon(:info, 'ic-info')}) +
      %(<div><p class="big" id="result-big">#{big}</p><p class="sub" id="result-sub">#{sub}</p></div></div>)
  end

  def at(body, key) = %(<time datetime="#{txt(body[key])}">#{txt(body[key])}</time>)

  def status_block(body, status)
    case status
    when 'pending' then result_block('info', '', '', hidden: true)
    when 'expired' then result_block('info', 'Expired', "This request expired at #{at(body, 'expires_at')}. Ask the agent for a new one.")
    when 'approved' then result_block('ok', 'Already approved.', 'Nothing more to do. You can close this page.')
    else result_block('info', 'Not pending', "This request is #{txt(status)}.")
    end
  end

  def zones(body)
    <<~HTML
      <section data-zone="verified" aria-labelledby="zv">
      <h2 id="zv">Verified facts</h2>
      <p class="zone-note">From the signed request. The console checked these.</p>
      <dl>#{verified_rows(body)}</dl>
      </section>
      <section data-zone="agent" aria-labelledby="za">
      <h2 id="za">#{icon(:quote)}<span>Written by the requesting agent, unverified</span></h2>
      <p class="zone-note">The console did not check this text. It can be wrong or misleading, and it does not change the risk above.</p>
      #{agent_rows(body)}
      </section>
    HTML
  end

  def disclosures(body, body_string)
    hidden = body_string.match?(HIDDEN) ? '<p class="muted">Hidden characters are shown as [U+XXXX]; the hash is over the original bytes.</p>' : ''
    <<~HTML
      <details class="sec" data-zone="technical"><summary>Technical details</summary><dl>#{technical_rows(body)}</dl></details>
      <details class="sec" data-zone="signed"><summary>Show exact signed text</summary>
      <pre>#{txt(body_string)}</pre>
      <p class="muted">SHA-256 of the signed text: <code id="hash">computed in your browser</code></p>
      #{hidden}</details>
    HTML
  end

  def approve_form(body)
    <<~HTML
      <div id="away" class="approve-info">
      <p id="inapp" class="hint" hidden>Open in Safari for passkeys</p>
      <p class="lead">Approve this request with your passkey and a code.</p>
      <p class="muted">Not approving? Close this page. It expires at #{at(body, 'expires_at')}.</p>
      </div>
      <form id="approve">
      <p class="recap">#{risk_span(RISK.fetch(body['type'], :high))}<span>· #{txt(recap_text(body))}</span></p>
      #{MSG}
      <div class="row">
      <div class="field"><label class="vis-label" for="totp">Authenticator code</label>
      <input class="code" id="totp" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" enterkeyhint="go"></div>
      <button id="go" type="submit" disabled>Approve with passkey</button>
      </div>
      </form>
      <noscript><p class="noscript">Approving needs JavaScript and a passkey. Use the terminal fallback instead.</p></noscript>
    HTML
  end

  APPROVE_JS = <<~'JS'
    const $=i=>document.getElementById(i),body=JSON.parse(d.body),exp=Date.parse(body.expires_at);
    const form=$('approve'),totp=$('totp'),go=$('go'),res=$('result'),away=$('away'),count=$('countdown');
    const hm=ms=>new Date(ms).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
    document.querySelectorAll('time[datetime]').forEach(t=>{const ms=Date.parse(t.getAttribute('datetime'));if(!isNaN(ms))t.textContent=hm(ms)+' local'});
    sha(d.body).then(b=>{$('hash').textContent=[...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join('')});
    if(form){
      const ua=navigator.userAgent,hint=$('inapp');
      if(hint&&(/FBAN|FBAV|Instagram|Line\/|MicroMessenger|LinkedInApp|Twitter|Snapchat|Slack|GSA\/|; wv\)/.exec(ua)||(/iPhone|iPad|iPod/.exec(ua)&&!/Safari\//.exec(ua))))hint.hidden=false;
      let tick,locked=false;
      const note=t=>{msg.textContent=t;form.classList.toggle('has-msg',t!=='')};
      const sync=()=>{go.disabled=locked||totp.value.length!==6};
      const end=(kind,big,sub)=>{clearInterval(tick);form.remove();away.remove();count.remove();document.body.classList.remove('has-bar');res.dataset.kind=kind;$('result-big').textContent=big;$('result-sub').textContent=sub;res.hidden=false;window.scrollTo(0,0)};
      const gone=()=>end('info','Expired','This request expired at '+hm(exp)+'. Ask the agent for a new one.');
      const update=()=>{const left=exp-Date.now();if(left<-60000)return gone();count.textContent=left>0?'Expires in about '+Math.max(1,Math.ceil(left/60000))+' min (at '+hm(exp)+' local)':'Expiring now'};
      const handle=(s,j)=>{
        if(s===200)return end('ok','Approved','The approval is recorded. You can close this page.');
        if(s===410)return gone();
        if(s===409&&j.error==='replay'){totp.value='';return note('That code was already used. Wait for the next code and try again.')}
        if(s===409&&j.error==='not_pending')return end('info','Approved elsewhere','This request was already approved elsewhere. Nothing more to do.');
        if(s===401&&j.error==='totp_invalid'){totp.value='';return note('That code did not match. Wait for the next code and try again.')}
        if(s===401&&j.error==='assertion_invalid')return note('The passkey was not accepted. Try again, or use the terminal fallback.');
        if(s===423){locked=true;totp.disabled=true;return note('Too many failed tries. Locked until '+hm(Date.parse(j.locked_until))+'.')}
        if(s===503)return note('The console is busy. Try again in a moment.');
        note('Refused ('+s+'): '+(j.error||'error'))};
      const run=async()=>{
        if(go.disabled)return;go.disabled=true;note('Waiting for your passkey');
        try{const a=await assertion(d.body);a.totp=totp.value;const [s,j]=await post(location.pathname+'/approve',a);handle(s,j)}
        catch(e){note(e&&e.name==='NotAllowedError'?'Passkey cancelled. Tap Approve to try again.':'Failed: '+(e&&e.message?e.message:e))}
        sync()};
      totp.addEventListener('input',()=>{totp.value=totp.value.replace(/\D/g,'').slice(0,6);sync();if(!go.disabled)go.focus()});
      form.addEventListener('submit',e=>{e.preventDefault();run()});
      tick=setInterval(update,10000);update();
      if(!window.PublicKeyCredential){locked=true;totp.disabled=true;sync();note('This browser cannot use passkeys. Open the link in Safari or use the terminal fallback.')}
    }
  JS

  def approve(nonce, body_string, body, status, credentials)
    type = body['type']
    risk = RISK.fetch(type, :high)
    pending = status == 'pending'
    title = TYPE_TITLES.fetch(type, DEFAULT_TITLE)
    consequence = CONSEQUENCE[type]
    countdown = pending ? %(<p id="countdown" class="countdown">Expires at #{at(body, 'expires_at')}</p>) : ''
    inner = <<~HTML
      #{status_block(body, status)}
      <h1#{risk == :high ? ' class="hl-danger"' : ''}>#{esc(title)}</h1>
      <div class="meta">#{risk_span(risk)}#{countdown}</div>
      #{consequence ? %(<p class="risk-note">#{esc(consequence)}</p>) : ''}
      <p class="changes">#{txt(what_changes(body))}</p>
      #{links_html(body)}
      #{zones(body)}
      #{pending ? approve_form(body) : ''}
      #{disclosures(body, body_string)}
    HTML
    layout(nonce, title, inner, data_json(body: body_string, credentials: credentials), COMMON_JS + APPROVE_JS, body_class: pending ? 'has-bar' : nil)
  end

  def enroll(nonce, credentials, challenge_id, source, already_shown)
    inner = if already_shown
              '<p>The secret was already shown once and cannot be shown again.</p>'
    else
              '<p>Shown once, after a passkey check. Add it to any RFC 6238 TOTP app, one entry per machine.</p>' \
              '<button id="go" type="button">Show secret</button><div id="out" hidden>' \
              '<p><code id="secret"></code> <button id="c1" class="quiet" type="button">Copy secret</button></p>' \
              '<p><code id="uri"></code> <button id="c2" class="quiet" type="button">Copy URI</button></p><img id="qr" alt="QR code for the secret"></div>'
    end
    script = COMMON_JS + <<~JS
      const go=document.getElementById('go');
      if(go)go.onclick=async()=>{go.disabled=true;try{const a=await assertion(d.source);a.challenge_id=d.challenge_id;const [s,j]=await post(location.pathname,a);if(s!==200){msg.textContent='Refused ('+s+'): '+(j.error||'error');return}
      document.getElementById('secret').textContent=j.secret;document.getElementById('uri').textContent=j.uri;if(j.qr_svg_b64)document.getElementById('qr').src='data:image/svg+xml;base64,'+j.qr_svg_b64;document.getElementById('out').hidden=false;go.hidden=true;
      document.getElementById('c1').onclick=()=>navigator.clipboard.writeText(j.secret);document.getElementById('c2').onclick=()=>navigator.clipboard.writeText(j.uri)}catch(e){fail(e);go.disabled=false}};
    JS
    layout(nonce, 'Enroll the TOTP secret', "#{heading('Enroll the TOTP secret')}#{inner}#{MSG}", data_json(credentials: credentials, challenge_id: challenge_id, source: source), script)
  end

  def register(nonce)
    inner = '<p>Register this device passkey. Paste the one-time token the enroll command showed in your terminal.</p>' \
            '<input id="token" class="text" autocomplete="off" aria-label="One-time token">' \
            '<input id="label" class="text" placeholder="Label (optional)" aria-label="Label"><button id="go" type="button">Register passkey</button>'
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
    layout(nonce, 'Register a passkey', "#{heading('Register a passkey')}#{inner}#{MSG}", data_json(credentials: []), script)
  end

  def heading(title) = "<h1>#{esc(title)}</h1>"

  def notice(nonce, title, text) = layout(nonce, title, "#{heading(title)}<p>#{esc(text)}</p>", data_json({}), '')
end
