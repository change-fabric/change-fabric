# frozen_string_literal: true

require 'erb'
require 'json'
require 'uri'

# The compose scene kind: simulated compose UI for walkthroughs that never
# sends anything. A neutral, unbranded mail window or text message composer
# is filled from a mailto: or sms: link the app really produced in an earlier
# live scene, or from an explicit spec. Its markup and styles are versioned
# templates in skills/walkthrough/reference/compose/; fields carry fixed ids
# (#to, #cc, #bcc, #subject, #body, #send) so scripted steps can type into
# them and click Send to show the sent state.
module WalkthroughCompose
  KIND = 'compose'
  CHANNELS = %w[email sms].freeze
  FIELDS = %w[channel to cc bcc subject body].freeze
  TEMPLATE_VERSION = 1
  LINK_RE = /\A(mailto|sms|smsto|tel):/i

  module_function

  def compose?(scene) = scene['kind'] == KIND

  def sms?(spec) = spec['channel'] == 'sms'

  # -- link parsing ----------------------------------------------------------

  # A mailto:, sms:, or tel: URL as { channel, to, cc, bcc, subject, body }.
  # Recipients are lists; percent escapes decode, and bodies keep their line
  # breaks (CRLF becomes LF).
  def parse_link(href)
    raise ArgumentError, "not a mailto, sms, or tel link: #{href}" unless href.to_s.match?(LINK_RE)

    raw_scheme, rest = href.to_s.split(':', 2)
    scheme = raw_scheme.downcase
    path, query = rest.to_s.split('?', 2)
    # Some apps write sms:+1555&body=hi (the older iOS form) with no `?`.
    path, query = path.split('&', 2) if scheme.start_with?('sms') && query.nil?
    params = query_params(query)
    case scheme
    when 'mailto'
      { 'channel' => 'email', 'to' => recipients(decode(path)) + recipients(params['to']), 'cc' => recipients(params['cc']),
        'bcc' => recipients(params['bcc']), 'subject' => params['subject'].to_s, 'body' => params['body'].to_s }
    when 'tel' then { 'channel' => 'tel', 'to' => recipients(decode(path)) }
    else { 'channel' => 'sms', 'to' => recipients(decode(path)), 'body' => params['body'].to_s }
    end
  end

  def query_params(query)
    return {} if query.nil? || query.empty?

    query.split('&').each_with_object({}) do |pair, out|
      key, value = pair.split('=', 2)
      out[decode(key).downcase] = decode(value.to_s)
    end
  end

  # RFC 6068 keeps + literal (a phone number's leading +), so this is URI
  # component decoding, not form decoding.
  def decode(text) = URI.decode_uri_component(text.to_s).gsub("\r\n", "\n")

  def recipients(text) = text.to_s.split(',').map(&:strip).reject(&:empty?)

  # -- validation ------------------------------------------------------------

  # `scenes` is { orders: { id => order }, realtime: [live scene ids] }.
  def errors(scene, scenes)
    spec = scene['compose']
    return [ 'compose is required for a compose scene' ] unless spec.is_a?(Hash)

    errs = []
    errs << 'a compose scene has no screen; it renders the built-in compose UI' if scene.key?('screen')
    errs << 'a compose scene has no store' if scene.key?('store')
    from = spec['from_scene']
    if from
      errs << 'compose.from_scene excludes explicit fields' unless (spec.keys - %w[from_scene bar sent]).empty?
      errs.concat(from_errors(from, scene, scenes))
    else
      errs.concat(explicit_errors(spec))
    end
    errs
  end

  def from_errors(from, scene, scenes)
    orders = scenes.fetch(:orders)
    return [ "compose.from_scene #{from} is not a scene" ] unless orders.key?(from)
    return [ "compose.from_scene #{from} must be an earlier scene" ] if orders[from] >= scene['order'].to_i
    return [ "compose.from_scene #{from} must be a live scene" ] unless scenes.fetch(:realtime).include?(from)

    []
  end

  def explicit_errors(spec)
    errs = []
    unknown = spec.keys - FIELDS - %w[bar sent]
    errs << "compose has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    errs << "compose.channel must be one of #{CHANNELS.join(', ')}" unless CHANNELS.include?(spec['channel'])
    %w[to cc bcc].each do |k|
      v = spec[k]
      errs << "compose.#{k} must be a string or a list of strings" unless v.nil? || v.is_a?(String) || (v.is_a?(Array) && v.all?(String))
    end
    errs << 'compose.to is required' if Array(spec['to']).empty?
    errs << 'an sms compose takes only to and body' if sms?(spec) && (spec.keys & %w[cc bcc subject]).any?
    errs
  end

  # -- resolution ------------------------------------------------------------

  # The explicit spec, normalized to lists, or the last email or sms link in
  # `links` (the source scene's captured links.json, nil if not captured).
  def resolve(scene, links: nil)
    spec = scene['compose']
    from = spec['from_scene']
    return labels(spec, normalize(spec)) unless from
    raise ArgumentError, "capture #{from} before #{scene['id']}" if links.nil?

    link = links.reverse.find { |l| CHANNELS.include?(l['channel']) }
    raise ArgumentError, "#{from} opened no mailto or sms link for #{scene['id']}" unless link

    labels(spec, normalize(link))
  end

  # Optional storyboard wording: `bar` titles the window, `sent` replaces the
  # status shown after Send (e.g. to mark the window as an illustration).
  def labels(spec, out) = out.merge(spec.slice('bar', 'sent'))

  def normalize(spec)
    out = { 'channel' => spec['channel'], 'to' => Array(spec['to']), 'body' => spec['body'].to_s }
    out.merge!('cc' => Array(spec['cc']), 'bcc' => Array(spec['bcc']), 'subject' => spec['subject'].to_s) unless sms?(spec)
    out
  end

  # -- the built-in UI -------------------------------------------------------

  # The templates live with the skill, so an installed script and its
  # templates sit in two trees; the checkout is tried first, then installs.
  def template_roots
    [ File.expand_path('../skills/walkthrough/reference/compose', __dir__),
      File.join(Dir.home, '.claude', 'skills', 'cf:walkthrough', 'reference', 'compose'),
      File.join(Dir.home, '.config', 'opencode', 'skills', 'cf-walkthrough', 'reference', 'compose') ]
  end

  def template(name)
    found = template_roots.map { |r| File.join(r, name) }.find { |f| File.file?(f) }
    raise ArgumentError, "compose template not found: #{name}" unless found

    File.read(found)
  end

  def fill(text, values) = text.gsub(/\{\{(\w+)\}\}/) { values.fetch(Regexp.last_match(1)) }

  def esc(text) = ERB::Util.html_escape(text.to_s)

  # The compose page for one device ("desktop" or "phone").
  def html(spec, device)
    sms = sms?(spec)
    channel = sms ? 'sms' : 'email'
    values = { 'css' => template("#{channel}.css"), 'script' => template('compose.js'), 'device' => esc(device),
               'body' => esc(spec['body']), 'send' => send_button, 'status' => status_line(spec['sent']),
               'bar' => esc(spec['bar'] || 'New message') }
    values.merge!(sms ? { 'to' => esc(Array(spec['to']).join(', ')) } : { 'rows' => email_rows(spec) })
    fill(template("#{channel}.html"), values)
  end

  def send_button = '<button id="send" class="send" type="button">Send</button>'

  def status_line(sent = nil)
    attr = sent ? %( data-sent="#{esc(sent)}") : ''
    %(<span id="status" class="status" role="status"#{attr}></span>)
  end

  def field(id, label, values)
    %(<div class="row"><label for="#{id}">#{label}</label><input id="#{id}" value="#{esc(Array(values).join(', '))}"></div>)
  end

  def email_rows(spec)
    rows = [ field('to', 'To', spec['to']) ]
    [ %w[cc Cc], %w[bcc Bcc] ].each { |key, label| rows << field(key, label, spec[key]) unless Array(spec[key]).empty? }
    rows << field('subject', 'Subject', spec['subject'])
    rows.join("\n")
  end

  private_class_method :query_params, :decode, :recipients, :sms?, :from_errors, :explicit_errors, :normalize, :labels,
                       :template_roots, :esc, :send_button, :status_line, :field, :email_rows
end
