# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'openssl'
require 'securerandom'
require 'time'
require_relative 'shared'
require_relative 'pages'

# The approval console: every route, over an injected store, KMS, DM sender and
# clock. A handler call builds one of these; tests build one over in-memory
# fakes and call `call(event)` directly.
class ApprovalConsoleApp
  Canonical = ApprovalConsole::Canonical
  Totp = ApprovalConsole::Totp
  Base32 = ApprovalConsole::Base32
  Verifier = ApprovalConsole::Verifier
  Cbor = ApprovalConsole::Cbor

  MAX_BODY = 32 * 1024
  SKEW = 300
  LOCK_AFTER = 5
  LOCK_BASE = 900
  LOCK_MAX = 86_400
  OFFLINE_GRACE = 86_400
  REQUESTS_PER_HOUR = 20
  TOKEN_WINDOW = 900
  RETRIES = 3
  REC_TTL = 30 * 86_400
  UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  MACHINE_ROUTE = %r{\A/m/(?<mid>#{UUID})(?<rest>/.*)?\z}
  REQUEST_ROUTE = %r{\A/r/(?<rid>#{UUID})(?<tail>/approve|/proof)?\z}
  ERRORS = [ JSON::ParserError, Verifier::Reject, Cbor::Error, OpenSSL::OpenSSLError, ArgumentError, KeyError, Canonical::Invalid ].freeze

  class HttpError < StandardError
    attr_reader :status, :code, :extra

    def initialize(status, code, **extra)
      super(code)
      @status = status
      @code = code
      @extra = extra
    end
  end

  Request = Struct.new(:method, :path, :headers, :body, :host, keyword_init: true)

  def initialize(store:, kms:, dm:, clock: -> { Time.now.utc }, qr: ConsoleQr.method(:svg), logger: nil)
    @store = store
    @kms = kms
    @dm = dm
    @clock = clock
    @qr = qr
    @logger = logger
  end

  def call(event)
    req = parse_event(event)
    response = dispatch(req)
    log(req, response[:statusCode])
    response
  rescue HttpError => e
    out = json(e.status, { error: e.code }.merge(e.extra))
    log(req, e.status)
    out
  end

  private

  def now = @clock.call

  def log(req, status)
    return unless @logger && req

    @logger.call(JSON.generate(route: route_name(req.path), status: status))
  end

  # Ids are uuids and safe to log; everything else collapses to its route shape.
  def route_name(path) = path.to_s.gsub(/#{UUID}/o, ':id')[0, 80]

  def parse_event(event)
    http = event.dig('requestContext', 'http') || {}
    body = event['body'].to_s
    body = Base64.decode64(body) if event['isBase64Encoded']
    raise HttpError.new(413, 'too_large') if body.bytesize > MAX_BODY

    headers = (event['headers'] || {}).to_h { |key, value| [ key.to_s.downcase, value.to_s ] }
    host = event.dig('requestContext', 'domainName').to_s
    raise HttpError.new(400, 'no_host') if host.empty?

    Request.new(method: http['method'].to_s.upcase, path: http['path'] || event['rawPath'].to_s, headers: headers, body: body, host: host)
  end

  def dispatch(req)
    verb = req.method
    return register_page if verb == 'GET' && req.path == '/register'
    return register_options(req) if verb == 'POST' && req.path == '/register/options'
    return register_verify(req) if verb == 'POST' && req.path == '/register/verify'

    match = MACHINE_ROUTE.match(req.path) or raise HttpError.new(404, 'not_found')
    machine_route(req, match[:mid], match[:rest].to_s)
  end

  def machine_route(req, mid, rest)
    verb = req.method
    return post_requests(req, mid) if verb == 'POST' && rest == '/requests'
    return terminal(req, mid, sync: false) if verb == 'POST' && rest == '/terminal-approve'
    return terminal(req, mid, sync: true) if verb == 'POST' && rest == '/sync'
    return enroll_page(req, mid) if verb == 'GET' && rest == '/totp-enroll'
    return enroll_reveal(req, mid) if verb == 'POST' && rest == '/totp-enroll'

    sub = REQUEST_ROUTE.match(rest) or raise HttpError.new(404, 'not_found')
    rid = sub[:rid]
    case [ verb, sub[:tail] ]
    when [ 'GET', nil ] then approve_page(req, mid, rid)
    when [ 'POST', '/approve' ] then approve(req, mid, rid)
    when [ 'GET', '/proof' ] then proof(req, mid, rid)
    else raise HttpError.new(404, 'not_found')
    end
  end

  # ----- responses -------------------------------------------------------

  def json(status, payload)
    { statusCode: status, headers: { 'content-type' => 'application/json', 'cache-control' => 'no-store' }, body: JSON.generate(payload) }
  end

  def html(status, nonce, page)
    { statusCode: status, headers: ConsolePages.headers(nonce), body: page }
  end

  def nonce = SecureRandom.base64(18)

  # ----- small helpers ---------------------------------------------------

  def b64u(bytes) = [ bytes ].pack('m0').tr('+/', '-_').delete('=')

  def unb64u(text)
    raise HttpError.new(400, 'bad_encoding') unless text.is_a?(String) && text.match?(/\A[A-Za-z0-9_-]*\z/)

    (text.tr('-_', '+/') + ('=' * ((4 - (text.length % 4)) % 4))).unpack1('m0')
  rescue ArgumentError
    raise HttpError.new(400, 'bad_encoding')
  end

  def sha_hex(text) = Digest::SHA256.hexdigest(text.to_s.b)

  def stamp(time) = time.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

  def json_body(req)
    data = JSON.parse(req.body)
    raise HttpError.new(400, 'bad_json') unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise HttpError.new(400, 'bad_json')
  end

  def pk(mid) = "M##{mid}"

  # ----- machine authentication -----------------------------------------

  def meta_for(mid) = @store.get(pk(mid), 'META')

  # Requests from a machine carry x-cf-timestamp and x-cf-signature: the
  # machine key's signature over method, path, SHA-256(body) and the timestamp.
  def authenticate!(req, mid)
    meta = meta_for(mid)
    stamp_header = req.headers['x-cf-timestamp'].to_s
    signature = req.headers['x-cf-signature'].to_s
    raise HttpError.new(401, 'unauthenticated') unless meta && meta['machine_key'] && stamp_header.match?(/\A\d{1,12}\z/)
    raise HttpError.new(401, 'unauthenticated') if (now.to_i - stamp_header.to_i).abs > SKEW

    message = [ req.method, req.path, sha_hex(req.body), stamp_header ].join("\n")
    raise HttpError.new(401, 'unauthenticated') unless machine_signature?(meta['machine_key'], unb64u(signature), message)

    meta
  rescue OpenSSL::OpenSSLError, HttpError
    raise HttpError.new(401, 'unauthenticated')
  end

  def machine_signature?(pem, signature, message)
    key = OpenSSL::PKey.read(pem)
    key.is_a?(OpenSSL::PKey::EC) ? key.verify('SHA256', signature, message) : key.verify(nil, signature, message)
  end

  # ----- lockout and failures -------------------------------------------

  def locked_until(meta)
    text = meta['locked_until']
    text.is_a?(String) ? Time.iso8601(text).utc : nil
  rescue ArgumentError
    nil
  end

  def check_lock!(meta)
    locked = locked_until(meta)
    raise HttpError.new(423, 'locked', locked_until: stamp(locked)) if locked && locked > now
  end

  # Counts one failure on the machine row (conditional on its version, so a
  # concurrent success and failure serialize) and then refuses the call.
  def refuse!(mid, status, code)
    RETRIES.times do
      meta = meta_for(mid)
      break unless meta

      break if @store.transact([ { op: :put, item: with_failure(meta), expect: { 'version' => meta['version'] } } ])
    end
    raise HttpError.new(status, code)
  end

  def with_failure(meta)
    next_meta = meta.merge('failures' => meta['failures'].to_i + 1, 'version' => meta['version'].to_i + 1)
    return next_meta if next_meta['failures'] < LOCK_AFTER

    lockouts = meta['lockouts'].to_i + 1
    next_meta.merge('failures' => 0, 'lockouts' => lockouts, 'locked_until' => stamp(now + [ LOCK_BASE * (2**(lockouts - 1)), LOCK_MAX ].min))
  end

  def success_meta(meta, step)
    meta.merge('last_step' => step, 'failures' => 0, 'locked_until' => nil, 'version' => meta['version'].to_i + 1)
  end

  # ----- shared checks ---------------------------------------------------

  def seed_for(mid)
    row = @store.get(pk(mid), 'SEED') or raise HttpError.new(409, 'no_seed')
    [ @kms.decrypt(unb64u(row['ciphertext']), { 'machine_id' => mid }), row ]
  end

  def credentials(rows) = rows.to_h { |row| [ row['sk'], row['cose'] ] }

  # Verifies one assertion whose challenge commits to `source`, against the
  # pinned credential rows. Returns [assertion sha, credential row, counter].
  def check_assertion(req, rows, fields, source)
    raise HttpError.new(401, 'assertion_invalid') unless fields.is_a?(Hash) && fields['credential_id'].is_a?(String)

    cred = rows.find { |row| row['sk'] == fields['credential_id'] } or raise HttpError.new(401, 'assertion_invalid')
    sha = Verifier.new(rp_id: req.host, credentials: credentials(rows)).assertion_sha(fields, source)
    counter = unb64u(fields['authenticator_data']).byteslice(33, 4).unpack1('N')
    stored = cred['sign_count'].to_i
    raise Verifier::Reject, 'signature counter did not advance' unless counter > stored || (counter.zero? && stored.zero?)

    [ sha, cred, counter ]
  rescue *ERRORS
    raise HttpError.new(401, 'assertion_invalid')
  end

  def receipt(kind:, mid:, body:, request_id:, assertion:, step:, channel:)
    payload = Canonical.serialize(
      'v' => 1, 'kind' => kind, 'machine_id' => mid, 'request_id' => request_id, 'body_sha256' => Canonical.body_sha256(body),
      'assertion_sha256' => assertion, 'totp_step' => step, 'channel' => channel, 'accepted_at' => stamp(now)
    )
    signature, key_id = @kms.sign(payload)
    { 'payload' => payload, 'sig' => b64u(signature), 'key_id' => key_id }
  end

  # ----- registration ----------------------------------------------------

  def register_page
    value = nonce
    html(200, value, ConsolePages.register(value))
  end

  def boot_row(token)
    raise HttpError.new(400, 'bad_token') unless token.is_a?(String) && token.bytesize.between?(16, 200)

    row = @store.get("BOOT##{sha_hex(token)}", 'BOOT')
    raise HttpError.new(401, 'invalid_token') unless row && row['valid_until'].to_i > now.to_i

    row
  end

  def register_options(req)
    data = json_body(req)
    token = data['token']
    boot = boot_row(token)
    rows = @store.query('CRED')
    require_existing_credential!(req, rows, data, token) unless rows.empty?
    challenge = b64u(SecureRandom.random_bytes(32))
    # assertion_ok records that an existing passkey authorized this token, which
    # verify re-checks against the credential set at commit time.
    @store.transact([ { op: :put, item: boot.merge('challenge' => challenge, 'assertion_ok' => !rows.empty?), exists: true } ])
    json(200, publicKey: creation_options(req, boot, challenge, rows))
  end

  # A second credential needs an assertion from one already registered.
  def require_existing_credential!(req, rows, data, token)
    hash = sha_hex(token)
    unless data['assertion'].is_a?(Hash)
      raise HttpError.new(401, 'assertion_required', token_hash: hash, credentials: rows.map { |row| row['sk'] })
    end

    check_assertion(req, rows, data['assertion'], "cf-add-credential:#{hash}")
  end

  def creation_options(req, boot, challenge, rows)
    {
      rp: { id: req.host, name: 'cf approval console' }, challenge: challenge,
      user: { id: b64u('cf-approver'), name: 'approver', displayName: 'cf approver' },
      pubKeyCredParams: [ { type: 'public-key', alg: -7 }, { type: 'public-key', alg: -8 } ],
      authenticatorSelection: { residentKey: 'preferred', userVerification: 'required' },
      attestation: 'none', timeout: 60_000, excludeCredentials: rows.map { |row| { type: 'public-key', id: row['sk'] } },
      extensions: { cf_machine: boot['machine_id'] }
    }
  end

  def register_verify(req)
    data = json_body(req)
    boot = boot_row(data['token'])
    raise HttpError.new(400, 'no_challenge') unless boot['challenge']

    auth = registration_auth_data(req, data, boot)
    cred_id, cose = attested_credential(auth)
    raise Verifier::Reject, 'credential id does not match' unless b64u(cred_id) == data['id']

    Verifier.new(rp_id: req.host).cose_public_key(cose)
    store_credential(boot, data, b64u(cred_id), cose)
  rescue *ERRORS
    raise HttpError.new(400, 'registration_invalid')
  end

  def registration_auth_data(req, data, boot)
    client = JSON.parse(unb64u(data['client_data_json']))
    valid = client['type'] == 'webauthn.create' && client['origin'] == "https://#{req.host}" && client['challenge'] == boot['challenge']
    raise Verifier::Reject, 'client data does not match' unless valid

    att = Cbor.decode(unb64u(data['attestation_object']))
    raise Verifier::Reject, 'only fmt none is accepted' unless att.is_a?(Hash) && att['fmt'] == 'none' && att['authData'].is_a?(String)

    auth = att['authData'].b
    raise Verifier::Reject, 'authenticator data is too short' if auth.bytesize < 55
    raise Verifier::Reject, 'rpIdHash mismatch' unless auth.byteslice(0, 32) == Digest::SHA256.digest(req.host)

    flags = auth.getbyte(32)
    raise Verifier::Reject, 'user presence, verification and attested data are required' unless flags & 0x45 == 0x45

    auth
  end

  def attested_credential(auth)
    length = auth.byteslice(53, 2).unpack1('n')
    raise Verifier::Reject, 'credential id is truncated' if auth.bytesize < 55 + length

    cred_id = auth.byteslice(55, length)
    cose, used = Cbor.decode_first(auth.byteslice(55 + length..))
    [ cred_id, cose.is_a?(Hash) ? auth.byteslice(55 + length, used) : raise(Verifier::Reject, 'public key is not a map') ]
  end

  # The credential set is serialized by a version row: two tokens that were
  # issued while it was empty cannot both commit as first credentials. A token
  # that commits into a non-empty set must carry an existing-passkey assertion.
  def store_credential(boot, data, cred_id, cose)
    RETRIES.times do
      registry = @store.get('CREDREG', 'REG')
      rows = @store.query('CRED')
      raise HttpError.new(401, 'assertion_required') unless rows.empty? || boot['assertion_ok']

      item = { 'pk' => 'CRED', 'sk' => cred_id, 'cose' => b64u(cose), 'sign_count' => 0, 'created_at' => stamp(now),
               'label' => data['label'].to_s[0, 64], 'machine_id' => boot['machine_id'] }
      ops = [ { op: :delete, key: { 'pk' => boot['pk'], 'sk' => 'BOOT' }, exists: true }, { op: :put, item: item, absent: true },
              { op: :put, item: { 'pk' => 'CREDREG', 'sk' => 'REG', 'version' => registry ? registry['version'].to_i + 1 : 1 }, expect: { 'version' => registry && registry['version'] } } ]
      return json(200, credential_id: cred_id) if @store.transact(ops)
    end
    raise HttpError.new(409, 'already_registered')
  end

  # ----- requests --------------------------------------------------------

  def post_requests(req, mid)
    authenticate!(req, mid)
    body = json_body(req)['body']
    parsed = parse_body!(body, mid)
    rid = parsed['request_id']
    created = Canonical.parse_time(parsed['created_at'])
    expires = Canonical.parse_time(parsed['expires_at'])
    raise HttpError.new(400, 'bad_window') if created > now + SKEW || expires <= now

    existing = @store.get(pk(mid), "REQ##{rid}")
    return replay_request(existing, body, req, mid, rid) if existing

    create_request(req, mid, body, parsed, expires)
  end

  def parse_body!(body, mid)
    parsed = Canonical.parse(body)
    raise HttpError.new(400, 'wrong_machine') unless parsed['machine_id'] == mid

    parsed
  rescue Canonical::Invalid => e
    raise HttpError.new(400, 'invalid_body', detail: e.message[0, 200])
  end

  def link(req, mid, rid) = "https://#{req.host}/m/#{mid}/r/#{rid}"

  def replay_request(existing, body, req, mid, rid)
    raise HttpError.new(409, 'request_conflict') unless existing['body'] == body

    json(200, request_id: rid, url: link(req, mid, rid), status: existing['status'])
  end

  # The hourly counter and the request row commit together, before any DM or
  # KMS call, so a flood costs nothing beyond this one conditional write.
  def create_request(req, mid, body, parsed, expires)
    rid = parsed['request_id']
    slot = "RATE##{now.strftime('%Y%m%d%H')}"
    RETRIES.times do
      row = @store.get(pk(mid), slot)
      count = row ? row['count'].to_i : 0
      raise HttpError.new(429, 'rate_limited') if count >= REQUESTS_PER_HOUR

      ops = [ { op: :put, item: request_item(mid, rid, body, parsed, expires), absent: true },
              { op: :put, item: { 'pk' => pk(mid), 'sk' => slot, 'count' => count + 1, 'expires_at' => now.to_i + 7200 }, expect: { 'count' => row && count } } ]
      next unless @store.transact(ops)

      @dm.notify("Approval requested: #{parsed['type']} for #{parsed['repo']} at #{parsed['sha'][0, 7]}\n#{link(req, mid, rid)}")
      return json(201, request_id: rid, url: link(req, mid, rid), status: 'pending')
    end
    raise HttpError.new(409, 'request_conflict')
  end

  def request_item(mid, rid, body, parsed, expires)
    { 'pk' => pk(mid), 'sk' => "REQ##{rid}", 'body' => body, 'body_sha256' => Canonical.body_sha256(body), 'status' => 'pending',
      'type' => parsed['type'], 'valid_until' => expires.to_i, 'created_at' => stamp(now), 'expires_at' => expires.to_i + 86_400 }
  end

  # ----- the approval page -----------------------------------------------

  def approve_page(req, mid, rid)
    item = @store.get(pk(mid), "REQ##{rid}")
    value = nonce
    return html(404, value, ConsolePages.notice(value, 'Not found', 'No such request.')) unless item

    status = item['status'] == 'pending' && item['valid_until'].to_i <= now.to_i ? 'expired' : item['status']
    rows = @store.query('CRED')
    html(200, value, ConsolePages.approve(value, item['body'], JSON.parse(item['body']), status, rows.map { |row| row['sk'] }))
  end

  # ----- approve (phone) -------------------------------------------------

  def approve(req, mid, rid)
    data = json_body(req)
    RETRIES.times do
      outcome = approve_once(req, mid, rid, data)
      return outcome unless outcome == :conflict
    end
    raise HttpError.new(503, 'busy')
  end

  def approve_once(req, mid, rid, data)
    meta = meta_for(mid) or raise HttpError.new(404, 'not_found')
    item = @store.get(pk(mid), "REQ##{rid}") or raise HttpError.new(404, 'not_found')
    return stored_proof(mid, rid, data) if item['status'] == 'approved'

    check_lock!(meta)
    raise HttpError.new(409, 'not_pending') unless item['status'] == 'pending'
    raise HttpError.new(410, 'expired') unless within_window?(Canonical.parse(item['body']))

    rows = @store.query('CRED')
    checked = refusing(mid) { check_assertion(req, rows, data, item['body']) }
    step = refusing(mid) { totp_step(mid, meta, data['totp']) }
    commit_approval(mid, rid, item, meta, data, checked, step)
  end

  # Any HttpError from a credential check counts one failure before it surfaces.
  def refusing(mid)
    yield
  rescue HttpError => e
    refuse!(mid, e.status, e.code)
  end

  def within_window?(parsed)
    created = Canonical.parse_time(parsed['created_at'])
    expires = Canonical.parse_time(parsed['expires_at'])
    now >= created && now <= expires
  end

  # A retry of an approved request returns the stored record unchanged, but
  # only to a caller that presents the very assertion that was accepted.
  def stored_proof(mid, rid, data)
    rec = @store.get(pk(mid), "REC##{rid}") or raise HttpError.new(409, 'not_pending')
    raise HttpError.new(409, 'not_pending') unless rec['proof']['signature'] == data['signature']

    json(200, proof: rec['proof'])
  end

  def totp_step(mid, meta, code)
    seed, = seed_for(mid)
    result = Totp.check(seed, code, now: now, last_step: meta['last_step'])
    return result.step if result.ok?

    raise HttpError.new(result.reason == :replay ? 409 : 401, result.reason == :replay ? 'replay' : 'totp_invalid')
  end

  # One transaction: the fence advance and failure reset, the request's
  # pending-to-approved move, the passkey counter and the immutable record.
  def commit_approval(mid, rid, item, meta, data, checked, step)
    sha, cred, counter = checked
    receipt = receipt(kind: 'webauthn+totp', mid: mid, body: item['body'], request_id: rid, assertion: sha, step: step, channel: 'console')
    proof = { 'kind' => 'webauthn+totp', 'body' => item['body'], 'credential_id' => cred['sk'], 'totp_step' => step, 'receipt' => receipt }
              .merge(data.slice('authenticator_data', 'client_data_json', 'signature'))
    ops = [
      { op: :put, item: success_meta(meta, step), expect: { 'version' => meta['version'] } },
      { op: :put, item: item.merge('status' => 'approved', 'approved_at' => stamp(now)), expect: { 'status' => 'pending' } },
      { op: :put, item: cred.merge('sign_count' => counter), expect: { 'sign_count' => cred['sign_count'] } },
      { op: :put, item: rec_item(mid, rid, proof), absent: true }
    ]
    @store.transact(ops) ? json(200, proof: proof) : :conflict
  end

  def rec_item(mid, rid, proof)
    { 'pk' => pk(mid), 'sk' => "REC##{rid}", 'proof' => proof, 'created_at' => stamp(now), 'expires_at' => now.to_i + REC_TTL }
  end

  # ----- proof (CLI poll) ------------------------------------------------

  def proof(req, mid, rid)
    authenticate!(req, mid)
    rec = @store.get(pk(mid), "REC##{rid}")
    return json(200, status: 'approved', proof: rec['proof']) if rec

    item = @store.get(pk(mid), "REQ##{rid}") or raise HttpError.new(404, 'not_found')
    pending = item['status'] == 'pending'
    json(200, status: pending && item['valid_until'].to_i <= now.to_i ? 'expired' : item['status'])
  end

  # ----- terminal approvals and sync (machine signed) --------------------

  def terminal(req, mid, sync:)
    meta = authenticate!(req, mid)
    data = json_body(req)
    parsed = parse_body!(data['body'], mid)
    rid = parsed['request_id']
    existing = @store.get(pk(mid), "REC##{rid}")
    return replayed_terminal(existing, data['body']) if existing

    check_lock!(meta)
    RETRIES.times do
      meta = meta_for(mid)
      check_lock!(meta)
      outcome = terminal_once(mid, meta, data, parsed, sync)
      return outcome unless outcome == :conflict
    end
    raise HttpError.new(503, 'busy')
  end

  def replayed_terminal(existing, body)
    raise HttpError.new(409, 'request_conflict') unless existing['proof']['body'] == body && existing['proof']['kind'] == 'totp-terminal'

    json(200, proof: existing['proof'])
  end

  def terminal_once(mid, meta, data, parsed, sync)
    step = sync ? sync_step(mid, meta, data, parsed) : online_step(mid, meta, data, parsed)
    body = data['body']
    rid = parsed['request_id']
    proof = { 'kind' => 'totp-terminal', 'body' => body, 'totp_step' => step,
              'receipt' => receipt(kind: 'totp-terminal', mid: mid, body: body, request_id: rid, assertion: nil, step: step, channel: 'terminal') }
    ops = [ { op: :put, item: success_meta(meta, step), expect: { 'version' => meta['version'] } }, { op: :put, item: rec_item(mid, rid, proof), absent: true } ]
    @store.transact(ops) ? json(200, proof: proof) : :conflict
  end

  def online_step(mid, meta, data, parsed)
    raise HttpError.new(410, 'expired') unless within_window?(parsed)

    refusing(mid) { totp_step(mid, meta, data['code']) }
  end

  # An offline approval made at `step` in the past, accepted inside the 24 h
  # grace and only if the request's window covered that step. A step at or
  # below the stored one is a conflict, not a guess, so it counts no failure.
  def sync_step(mid, meta, data, parsed)
    step = data['step']
    raise HttpError.new(400, 'bad_step') unless step.is_a?(Integer) && step >= 0

    seconds = step * Totp::STEP_SECONDS
    created = Canonical.parse_time(parsed['created_at']).to_i
    expires = Canonical.parse_time(parsed['expires_at']).to_i
    raise HttpError.new(410, 'outside_grace') if seconds > now.to_i + Totp::STEP_SECONDS || now.to_i - seconds > OFFLINE_GRACE + Totp::STEP_SECONDS
    raise HttpError.new(410, 'outside_window') if seconds + Totp::STEP_SECONDS <= created || seconds > expires

    seed, = seed_for(mid)
    code = data['code'].to_s
    valid = code.match?(/\A\d{6}\z/) && Totp.same_code?(Totp.code(seed, step), code)
    refuse!(mid, 401, 'totp_invalid') unless valid
    raise HttpError.new(409, 'conflict') if meta['last_step'] && step <= meta['last_step']

    step
  end

  # ----- TOTP secret reveal (once, after a passkey assertion) -------------

  def enroll_page(req, mid)
    seed = @store.get(pk(mid), 'SEED')
    value = nonce
    return html(404, value, ConsolePages.notice(value, 'Not found', 'This machine has no secret to show.')) unless seed

    rows = @store.query('CRED')
    return html(200, value, ConsolePages.enroll(value, [], '', '', true)) if seed['shown_at']

    challenge = SecureRandom.hex(16)
    @store.transact([ { op: :put, item: { 'pk' => pk(mid), 'sk' => "ENR##{challenge}", 'valid_until' => now.to_i + SKEW, 'expires_at' => now.to_i + 3600 }, absent: true } ])
    html(200, value, ConsolePages.enroll(value, rows.map { |row| row['sk'] }, challenge, enroll_source(mid, challenge), false))
  end

  def enroll_source(mid, challenge) = "cf-totp-enroll:#{mid}:#{challenge}"

  def enroll_reveal(req, mid)
    data = json_body(req)
    challenge = data['challenge_id'].to_s
    row = challenge.match?(/\A[0-9a-f]{32}\z/) ? @store.get(pk(mid), "ENR##{challenge}") : nil
    raise HttpError.new(401, 'challenge_invalid') unless row && row['valid_until'].to_i > now.to_i

    meta = meta_for(mid) or raise HttpError.new(404, 'not_found')
    check_lock!(meta)
    rows = @store.query('CRED')
    _, cred, counter = refusing(mid) { check_assertion(req, rows, data, enroll_source(mid, challenge)) }
    seed, seed_row = seed_for(mid)
    raise HttpError.new(409, 'already_shown') if seed_row['shown_at']

    reveal(mid, challenge, seed, seed_row, cred, counter, meta)
  end

  def reveal(mid, challenge, seed, seed_row, cred, counter, meta)
    ops = [
      { op: :delete, key: { 'pk' => pk(mid), 'sk' => "ENR##{challenge}" }, exists: true },
      { op: :put, item: seed_row.merge('shown_at' => stamp(now)), expect: { 'shown_at' => nil } },
      { op: :put, item: cred.merge('sign_count' => counter), expect: { 'sign_count' => cred['sign_count'] } },
      { op: :put, item: meta.merge('failures' => 0, 'version' => meta['version'].to_i + 1), expect: { 'version' => meta['version'] } }
    ]
    raise HttpError.new(409, 'already_shown') unless @store.transact(ops)

    secret = Base32.encode(seed)
    uri = "otpauth://totp/cf:#{meta['label'].to_s.gsub(/[^A-Za-z0-9._-]/, '-')}?secret=#{secret}&issuer=cf"
    svg = @qr.call(uri)
    json(200, secret: secret, uri: uri, qr_svg_b64: svg && Base64.strict_encode64(svg))
  end
end
