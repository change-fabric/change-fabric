# frozen_string_literal: true

require "json"
require "uri"
require_relative "../../approval_console/infra/lambda/console"
require_relative "soft_authenticator"
require_relative "console_fakes"
require_relative "totp_enrollment"
require_relative "../../scripts/approval_console/host_health"
require_relative "../../scripts/approval_console/client"
require_relative "../../scripts/approval_console/remote"
require_relative "../../scripts/approval_console/recorder"
require_relative "../../scripts/change_policy"

# The real console app in process, over the in-memory store and KMS fakes,
# with a soft passkey standing in for the phone. Callers set ENV["HOME"] to a
# temp dir first, then call `start_phone_console`. Nothing touches the network
# or AWS.
module PhoneConsole
  include TotpEnrollment

  HOST = "abc123.lambda-url.us-east-1.on.aws"
  POLICY_SHA = "c" * 40

  FakePolicy = Struct.new(:approval_pins)

  def start_phone_console(now: Time.now.utc)
    @now = Time.at(now.to_i).utc
    @store = enroll_totp
    @db = MemoryStore.new
    @signer = SoftReceiptSigner.new
    @kms = FakeKms.new(@signer)
    @app = ApprovalConsoleApp.new(store: @db, kms: @kms, dm: FakeDm.new, clock: -> { @now }, qr: ->(_uri) { "<svg/>" })
    @passkey = SoftAuthenticator.new
    @counter = 0
    register_machine
  end

  def mid = @store.machine_id

  def register_machine
    key = @store.ensure_machine_key!
    @db.seed("pk" => "M##{mid}", "sk" => "META", "label" => "test", "machine_key" => key.public_to_pem, "failures" => 0, "version" => 0)
    @db.seed("pk" => "M##{mid}", "sk" => "SEED", "ciphertext" => SoftAuthenticator.b64(@kms.encrypt(@store.seed, "machine_id" => mid)))
    @db.seed("pk" => "CRED", "sk" => @passkey.credential_id, "cose" => SoftAuthenticator.b64(@passkey.cose_public_key), "sign_count" => 0)
    @store.pin!(base_url: "https://#{HOST}/", rp_id: HOST, credentials: @passkey.pinned,
                receipt_public_key: @signer.public_pem, receipt_key_id: "arn:aws:kms:test:key/receipts")
  end

  def transport
    lambda do |method, url, headers, body|
      path = URI(url).path
      event = { "requestContext" => { "http" => { "method" => method, "path" => path }, "domainName" => HOST },
                "rawPath" => path, "headers" => headers, "body" => method == "GET" ? nil : body }
      response = @app.call(event)
      [ response[:statusCode], response[:body] ]
    end
  end

  def client = ApprovalConsole::Client.for(@store, transport: transport, clock: -> { @now })

  def totp_code = ApprovalConsole::Totp.code(@store.seed, ApprovalConsole::Totp.step_for(@now))

  def pending_request_body = @db.items.values.find { |item| item["sk"].to_s.start_with?("REQ#") && item["status"] == "pending" }["body"]

  # Approves `body` on the "phone": passkey assertion plus the TOTP code.
  def phone_approve(body)
    @counter += 1
    rid = ApprovalConsole::Canonical.parse(body)["request_id"]
    fields = @passkey.assert(body, rp_id: HOST, counter: @counter)
    response = @app.call("requestContext" => { "http" => { "method" => "POST", "path" => "/m/#{mid}/r/#{rid}/approve" }, "domainName" => HOST },
                         "headers" => {}, "body" => JSON.generate(fields.merge("totp" => totp_code)))
    response[:statusCode]
  end

  # A sleeper for Remote.wait that approves the pending request at the first
  # poll, then lets three seconds pass.
  def approving_sleeper
    approved = false
    lambda do |_seconds|
      approved ||= phone_approve(pending_request_body) && true
      @now += 3
    end
  end

  def remote_io = { sleeper: approving_sleeper, clock: -> { @now } }

  # A verified phone proof for `attrs`, each on a new TOTP step (the console
  # spends a step once).
  def phone_proof(attrs)
    @now += 30
    result = ApprovalConsole::Remote.approve(attrs, store: @store, client: client, out: StringIO.new, **remote_io)
    raise "phone approval failed: #{result.error}" unless result.ok?

    result.proof
  end

  def authoritative_pins
    { "receipt_key_fingerprint" => ApprovalConsole::LocalStore.key_fingerprint(@signer.public_pem), "rp_id" => HOST }
  end

  def authority(pins: authoritative_pins)
    ChangePolicy::Authority.new(policy: FakePolicy.new(pins), policy_sha: POLICY_SHA, ref: "origin/main")
  end
end
