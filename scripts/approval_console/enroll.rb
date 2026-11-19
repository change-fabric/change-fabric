# frozen_string_literal: true

require 'digest'
require 'optparse'
require 'securerandom'
require 'time'
require 'uri'
require_relative 'aws_operator'
require_relative 'client'
require_relative 'sync'
require_relative 'totp'

module ApprovalConsoleCli
  # `enroll --url <function URL> --profile <aws profile>`: registers this
  # machine with a deployed console, using the human's own AWS profile as the
  # bootstrap authority. It never replaces a console row (every put is
  # conditional), so re-running it is safe.
  #
  # 1. Reads the console function's table and key ids, and refuses when the
  #    function's live URL is not the one given (the rpId must never change).
  # 2. Writes M#<id>/META with this machine's public signing key and
  #    M#<id>/SEED with the existing TOTP seed encrypted under KMS.
  # 3. With no passkey registered yet (or --add-passkey), mints a one-time
  #    bootstrap token shown only on /dev/tty, and waits up to 15 minutes for
  #    the passkey to be registered at <url>register from the phone.
  # 4. Pins the rpId, the passkey public keys and the receipt public key, then
  #    proves the machine signature with one signed read.
  module Enroll
    FUNCTION = 'cf-approval-console'
    TOKEN_WINDOW = 900
    POLL = 3
    URL_SHAPE = %r{\Ahttps://([a-z0-9]+\.lambda-url\.([a-z0-9-]+)\.on\.aws)/?\z}

    module_function

    def run(args, ctx)
      opts = parse(args, ctx.stderr) or return 1
      refusal = ApprovalConsoleCli.human_only_refusal(ctx.stdin, ctx.env, ctx.parents)
      return ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', refusal) if refusal
      unless ctx.store.enrolled?
        return ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', 'no TOTP seed on this machine; run totp-enroll first')
      end

      enroll(opts, ctx)
    rescue ApprovalConsole::AwsOperator::Failed => e
      ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', e.message)
    end

    def parse(args, stderr)
      opts = { function: FUNCTION }
      OptionParser.new do |o|
        o.on('--url URL') { |value| opts[:url] = value }
        o.on('--profile NAME') { |value| opts[:profile] = value }
        o.on('--function NAME') { |value| opts[:function] = value }
        o.on('--add-passkey') { opts[:add_passkey] = true }
      end.parse!(args.dup)
      match = URL_SHAPE.match(opts[:url].to_s)
      unless match && !opts[:profile].to_s.empty?
        stderr.puts 'usage: approval_console.rb enroll --url https://<id>.lambda-url.<region>.on.aws/ --profile <aws profile> ' \
                    '[--function NAME] [--add-passkey]'
        return nil
      end
      opts.merge(rp_id: match[1], region: match[2], base_url: "https://#{match[1]}/")
    rescue OptionParser::ParseError
      stderr.puts 'usage: approval_console.rb enroll --url URL --profile NAME'
      nil
    end

    def enroll(opts, ctx)
      operator = (ctx.io[:operator] || ->(**kw) { ApprovalConsole::AwsOperator.new(**kw) }).call(profile: opts[:profile], region: opts[:region])
      live = operator.function_url(opts[:function])
      unless live.chomp('/') == opts[:base_url].chomp('/')
        return ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', "#{opts[:function]} answers on #{live}, not #{opts[:base_url]}")
      end

      env = operator.function_env(opts[:function])
      seed_rows(operator, env, ctx)
      creds = passkeys(operator, env, opts, ctx) or return 1
      pin(operator, env, opts, creds, ctx)
      self_test(opts, ctx)
    end

    def seed_rows(operator, env, ctx)
      store = ctx.store
      mid = store.machine_id
      key = store.ensure_machine_key!
      now = ctx.clock.call.utc
      meta = { 'pk' => "M##{mid}", 'sk' => 'META', 'label' => store.label.to_s, 'machine_key' => key.public_to_pem,
               'created_at' => now.iso8601, 'failures' => 0, 'version' => 0 }
      note(ctx, "machine row: #{operator.put_new(env['TABLE_NAME'], meta)}")
      cipher = operator.encrypt_seed(env['SEED_KEY_ID'], store.seed, mid, dir: store.dir)
      note(ctx, "seed row: #{operator.put_new(env['TABLE_NAME'], 'pk' => "M##{mid}", 'sk' => 'SEED', 'ciphertext' => cipher)}")
    end

    # The registered passkeys, minting a bootstrap token first when none is
    # registered or --add-passkey asks for another. nil on timeout.
    def passkeys(operator, env, opts, ctx)
      table = env['TABLE_NAME']
      before = operator.credentials(table)
      return before unless before.empty? || opts[:add_passkey]

      token = ApprovalConsole::Base32.encode(SecureRandom.random_bytes(15))
      deadline = ctx.clock.call.to_i + TOKEN_WINDOW
      operator.put_new(table, 'pk' => "BOOT##{Digest::SHA256.hexdigest(token)}", 'sk' => 'BOOT', 'machine_id' => ctx.store.machine_id,
                              'valid_until' => deadline, 'expires_at' => deadline)
      show_token(ctx, opts, token) or return nil
      wait_for_new(operator, table, before, deadline, ctx)
    end

    # The token is a bearer credential for one registration, so it goes to the
    # terminal only, never stdout, stderr or a log.
    def show_token(ctx, opts, token)
      tty = ctx.tty_open.call
      unless tty
        ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', '/dev/tty cannot be opened to show the registration token')
        return false
      end
      tty.puts ''
      tty.puts "On your phone, open #{opts[:base_url]}register"
      tty.puts "Paste this one-time token (valid 15 minutes): #{token}"
      tty.puts 'Then approve the passkey prompt. This command continues on its own once the passkey is registered.'
      tty.flush
      true
    ensure
      tty.close if tty.respond_to?(:close)
    end

    def wait_for_new(operator, table, before, deadline, ctx)
      loop do
        creds = operator.credentials(table)
        return creds if (creds.keys - before.keys).any?

        if ctx.clock.call.to_i >= deadline
          ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', 'no passkey was registered within 15 minutes; run enroll again')
          return nil
        end
        ctx.sleeper.call(POLL)
      end
    end

    def pin(operator, env, opts, creds, ctx)
      pem = operator.receipt_public_pem(env['RECEIPT_KEY_ID'])
      ctx.store.pin!(base_url: opts[:base_url], rp_id: opts[:rp_id], credentials: creds, receipt_public_key: pem,
                     receipt_key_id: env['RECEIPT_KEY_ID'])
      note(ctx, "pinned #{creds.size} passkey(s) and the receipt key for #{opts[:rp_id]}")
    end

    # A signed read of a request id that cannot exist: 404 proves the console
    # accepted this machine's signature, 401 means META holds a different key.
    def self_test(_opts, ctx)
      client = ctx.io.key?(:client) ? ctx.io[:client] : ApprovalConsole::Client.for(ctx.store)
      client.proof(SecureRandom.uuid)
      ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', 'the console answered a request that should not exist')
    rescue ApprovalConsole::Client::Refused => e
      return ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', "the console rejected this machine's signature (#{e.code})") unless e.status == 404

      report = ApprovalConsole::Sync.run(store: ctx.store, client: client)
      note(ctx, "enrolled with the console; synced #{report.synced} offline approval(s)")
      0
    rescue ApprovalConsole::Client::Unreachable => e
      ApprovalConsoleCli.refuse(ctx.stderr, 'enroll', "pinned, but the console is unreachable (#{e.message})")
    end

    def note(ctx, text) = ctx.stderr.puts("[approval_console] #{text}")
  end
end
