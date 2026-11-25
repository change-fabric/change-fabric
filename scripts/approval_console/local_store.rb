# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'openssl'
require 'securerandom'
require 'socket'
require 'time'
require 'uri'
require_relative '../cf_secret_store'
require_relative 'totp'

module ApprovalConsole
  # The terminal path's protected state, kept under the cf secret store at
  # ~/.claude/cf/secrets/<machine slug>/approval/ (0700 dirs, 0600 files, read
  # denied to agent tools by secrets_read_guard.rb). No OS keychain API and no
  # platform branch. Every read, check and write of the counters runs under an
  # exclusive flock on a stable lock file and is fsynced before the lock is
  # released. Only `enroll!` and `seed` ever return the seed, and nothing here
  # logs it.
  #
  # One machine can be enrolled on several consoles (one per self-hosted
  # account), so the state splits in two:
  #
  #   approval/                      per machine
  #     totp_seed, machine_key.pem   one seed and one signing key; each console
  #                                  holds its own M#<id>/SEED and META rows
  #     console.json                 machine_id, label, default_console
  #     totp_state.json              the replay fence and lockout counters
  #     requests/                    bodies sent with --no-wait (+ .console)
  #   approval/consoles/<rp_id>/     per console
  #     console.json                 base_url, rp_id
  #     credentials.json             passkey and receipt key pins
  #     sync_state.json              last successful contact (offline bound)
  #     pending_sync.jsonl           offline approvals queued for this console
  #
  # A store is bound to one console: the one named by `console:`, else the
  # default (most recently enrolled). `pins(expect:)` on an unbound store
  # reads the console the authoritative pins name.
  #
  # Reads never rewrite the store. A single-console layout (base_url and rp_id
  # in approval/console.json, credentials.json beside it) is read in place as
  # one console, so released code and this code share it; only `migrate!`,
  # run by `enroll` or the `migrate` verb, moves it into consoles/<rp_id>/.
  class LocalStore
    class NotEnrolled < StandardError; end
    class AlreadyEnrolled < StandardError; end
    class PinMismatch < StandardError; end

    FILE_MODE = 0o600
    DIR_MODE = 0o700
    SEED_BYTES = 20
    LOCK_AFTER = 5
    LOCK_BASE = 900
    LOCK_MAX = 86_400
    OFFLINE_GRACE = 86_400
    MAX_PENDING = 10
    # An rpId is a DNS name. It also names a directory, so anything else
    # (a slash, '..', upper case) is never turned into a path.
    RP_ID = /\A[a-z0-9][a-z0-9-]{0,62}(\.[a-z0-9][a-z0-9-]{0,62})+\z/

    Outcome = Struct.new(:reason, :step, :locked_until, keyword_init: true) do
      def ok? = reason.nil?
    end

    # One slug per machine: a fixed-length hash of the host name, one path segment.
    def self.machine_slug(host = Socket.gethostname) = Digest::SHA256.hexdigest("machine:#{host}")[0, 32]

    attr_reader :slug

    def initialize(slug: self.class.machine_slug, console: nil)
      @slug = slug
      @console = console&.to_s
    end

    def self.rp_id?(value) = value.is_a?(String) && value.match?(RP_ID)

    def dir = File.join(CfSecretStore.dir(@slug), 'approval')

    def path(name) = File.join(dir, name)

    def enrolled? = File.file?(path('totp_seed'))

    # The same machine store bound to the console at `rp_id`.
    def for_console(rp_id) = self.class.new(slug: @slug, console: rp_id)

    # The rpId of every console this machine is enrolled on, sorted. A
    # single-console layout not yet migrated counts as one.
    def consoles
      root = path('consoles')
      listed = File.directory?(root) ? Dir.children(root).select { |name| self.class.rp_id?(name) && File.file?(File.join(root, name, 'console.json')) } : []
      (listed + [ legacy_console ].compact).uniq.sort
    end

    # Moves a single-console layout into consoles/<rp_id>/ and makes it the
    # default. Returns the moved rpId, or nil when there was nothing to move.
    # New files are written before old ones go, so an interrupted run is
    # finished by the next one. Only `enroll` and the `migrate` verb call it.
    def migrate!
      return nil unless legacy?

      File.open(path('consoles.lock'), File::RDWR | File::CREAT, FILE_MODE) do |lock|
        lock.flock(File::LOCK_EX)
        legacy? ? migrate_locked : nil
      end
    end

    def console_enrolled?(rp_id) = self.class.rp_id?(rp_id) && consoles.include?(rp_id)

    # The console a `pin!` set last, else the last one listed; nil with none.
    def default_console
      list = consoles
      named = read_json(path('console.json'))['default_console']
      list.include?(named) ? named : list.last
    end

    # The console this store is bound to: the one asked for, else the default.
    def console_id = @console || default_console

    def bound? = !@console.nil?

    # nil, or why a bound store cannot reach its console here.
    def unenrolled_reason
      return nil unless bound? && !console_enrolled?(console_id)

      "this repo's approval_pins.rp_id #{console_id.inspect} is not enrolled on this machine " \
        "(enrolled: #{consoles.empty? ? 'none' : consoles.join(', ')}); run enroll --url https://#{console_id}/ from a real terminal"
    end

    # Never overwrites an existing seed. Returns the raw bytes for the one-time reveal.
    def enroll!(label: Socket.gethostname)
      raise AlreadyEnrolled, 'a TOTP seed is already enrolled on this machine' if enrolled?

      ensure_dir
      seed = SecureRandom.random_bytes(SEED_BYTES)
      write_new(path('totp_seed'), seed)
      write_atomic(path('console.json'), JSON.pretty_generate('machine_id' => SecureRandom.uuid, 'label' => label.to_s))
      write_atomic(path('totp_state.json'), JSON.pretty_generate(blank_state))
      seed
    end

    # Removes a seed whose reveal failed, so a value the human never saw is not
    # left enrolled.
    def discard!
      FileUtils.rm_rf(Dir.glob(File.join(dir, '*')))
    end

    def seed
      require_enrolled!

      File.binread(path('totp_seed'))
    end

    # The machine's config merged with the bound console's (base_url, rp_id).
    def console = machine_config.merge(console_config)

    def machine_id = machine_config['machine_id']

    def label = machine_config['label']

    # Without a console URL the local fence is the only channel.
    def console_configured? = !console_config['base_url'].to_s.empty?

    def base_url = console_config['base_url']

    def console_config = console_file('console.json') { |file| read_json(file) } || {}

    # The P-256 key this machine signs console calls with. Created once at
    # `enroll`; its public half lives in the console's M#<id>/META row.
    def machine_key
      file = path('machine_key.pem')
      File.file?(file) ? OpenSSL::PKey.read(File.read(file)) : nil
    end

    def ensure_machine_key!
      require_enrolled!
      existing = machine_key
      return existing if existing

      key = OpenSSL::PKey::EC.generate('prime256v1')
      write_new(path('machine_key.pem'), key.to_pem)
      key
    end

    # Adds (or re-pins) the console at `rp_id`: base URL and rpId in its
    # console.json, the passkey public keys and the receipt public key in its
    # credentials.json. Other consoles are kept; this one becomes the default.
    def pin!(base_url:, rp_id:, credentials:, receipt_public_key:, receipt_key_id:)
      require_enrolled!
      raise ArgumentError, "#{rp_id.inspect} is not an rpId" unless self.class.rp_id?(rp_id)

      migrate!
      root = File.join(dir, 'consoles', rp_id)
      ensure_console_dir(rp_id)
      write_atomic(File.join(root, 'credentials.json'), JSON.pretty_generate(
                                                              'rp_id' => rp_id, 'credentials' => credentials,
                                                              'receipt_public_key' => receipt_public_key, 'receipt_key_id' => receipt_key_id
                                                            ))
      write_atomic(console_path(rp_id, 'console.json'), JSON.pretty_generate('base_url' => base_url, 'rp_id' => rp_id))
      write_atomic(path('console.json'), JSON.pretty_generate(machine_config.merge('default_console' => rp_id)))
    end

    # { 'rp_id', 'credentials' => {id => cose}, 'receipt_public_key' } or {}.
    # credentials.json is agent-writable, so a gate passes `expect:`, the
    # authoritative { 'receipt_key_fingerprint', 'rp_id' } from the base or
    # default branch's change_policy.approval_pins, and a mismatch raises.
    # An unbound store reads the console `expect` names; a bound one must be
    # that console.
    def pins(expect: nil)
      return read_pins(console_id) unless expect

      data = read_pins(pinned_console(expect['rp_id'].to_s))
      check_pins!(data, expect)
      data
    end

    # "sha256:<hex>" of the receipt public key's SubjectPublicKeyInfo DER.
    def self.key_fingerprint(pem)
      "sha256:#{Digest::SHA256.hexdigest(OpenSSL::PKey.read(pem.to_s).public_to_der)}"
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      nil
    end

    # Raises the local fence mirror to a step the console accepted, and records
    # a successful console contact for the offline bounds.
    def observe_step(step, now: Time.now)
      with_lock do
        state = read_state
        state['last_step'] = [ state['last_step'], step ].compact.max
        write_state(state)
        touch_sync(now)
      end
    end

    # Settles one queued offline approval, matched by body hash: `:synced`
    # removes it, `:conflict` keeps it (without its code) so status and the
    # gate see it.
    def settle(body_sha256, status, reason: nil, now: Time.now)
      with_lock do
        entries = pending.filter_map do |entry|
          next entry unless entry['body_sha256'] == body_sha256
          next nil if status == :synced

          entry.except('code').merge('status' => 'conflict', 'reason' => reason.to_s)
        end
        write_atomic(pending_path, entries.map { |entry| "#{JSON.generate(entry)}\n" }.join) if pending_path
        touch_sync(now) if status == :synced
      end
    end

    # Request bodies this machine sent with `request --no-wait`, for `wait`,
    # with the rpId of the console each was sent to beside it.
    def save_request(request_id, body)
      FileUtils.mkdir_p(path('requests'), mode: DIR_MODE)
      write_atomic(request_path(request_id, "json"), body)
      rp = console_id
      write_atomic(request_path(request_id, "console"), rp) if self.class.rp_id?(rp)
    end

    # The rpId a saved request was sent to, or nil (unknown, or saved before
    # multi-console).
    def request_console(request_id)
      rp = request_file(request_id, 'console')&.strip
      self.class.rp_id?(rp) ? rp : nil
    end

    def saved_request(request_id) = request_file(request_id, 'json')

    # Checks `code` against the seed under the lock and, on success, commits the
    # fence (`last_step`) and the optional `entry` for the sync queue in the
    # same locked write. Fails closed: any error is :error and nothing is
    # accepted. Reasons: :malformed, :invalid, :replay, :locked, :offline_limit,
    # :error. Raises NotEnrolled when there is no seed.
    def consume(code, now: Time.now, entry: nil)
      with_lock { decide(code, now, read_state, entry) }
    rescue NotEnrolled
      raise
    rescue StandardError
      Outcome.new(reason: :error)
    end

    def status(now: Time.now)
      state = enrolled? ? read_state : blank_state
      locked = locked_until(state)
      { enrolled: enrolled?, machine_id: machine_id, label: label, last_step: state['last_step'],
        failures: state['failures'].to_i, locked_until: locked && locked > now ? locked : nil,
        pending: unsynced.size, conflicts: conflicts.size, console_configured: console_configured?,
        consoles: consoles, default_console: default_console }
    end

    # The bound console's queue; [] with no console.
    def pending = (file = pending_path) ? read_lines(file) : []

    def conflicts = pending.select { |entry| entry['status'] == 'conflict' }

    # Queued offline approvals still waiting for a console receipt.
    def unsynced = pending.reject { |entry| entry['status'] == 'conflict' }

    private

    # Where the unmigrated single-console layout keeps each per-console file.
    # Its last_sync lives in totp_state.json, as released code writes it.
    LEGACY_FILES = { 'console.json' => 'console.json', 'credentials.json' => 'credentials.json',
                     'pending_sync.jsonl' => 'pending_sync.jsonl', 'sync_state.json' => 'totp_state.json' }.freeze

    def console_path(rp_id, name)
      return path(LEGACY_FILES.fetch(name)) if legacy_layout?(rp_id)

      File.join(dir, 'consoles', rp_id, name)
    end

    def legacy_layout?(rp_id) = rp_id == legacy_console && !File.file?(File.join(dir, 'consoles', rp_id, 'console.json'))

    # The rpId of the unmigrated single-console layout, or nil.
    def legacy_console
      return nil unless legacy?

      legacy_rp_id(read_json(path('console.json')), read_json(path('credentials.json')))
    end

    def machine_config = read_json(path('console.json'))

    def read_pins(rp_id) = self.class.rp_id?(rp_id) ? read_json(console_path(rp_id, 'credentials.json')) : {}

    # Yields the bound console's file `name` when the store has a console with a
    # valid rpId; nil otherwise. The one place an rpId becomes a path.
    def console_file(name)
      rp = console_id
      self.class.rp_id?(rp) ? yield(console_path(rp, name)) : nil
    end

    def request_path(request_id, ext) = File.join(path('requests'), "#{request_id}.#{ext}")

    def request_file(request_id, ext)
      return nil unless request_id.to_s.match?(/\A[0-9a-f-]{36}\z/)

      file = request_path(request_id, ext)
      File.file?(file) ? File.read(file) : nil
    end

    # The console whose pins a gate checks against the authoritative `wanted`.
    def pinned_console(wanted)
      return @console if bound?
      return wanted if console_enrolled?(wanted)

      raise PinMismatch, "no local rpId pin matches the authoritative approval_pins.rp_id #{wanted.inspect} " \
                         "(enrolled: #{consoles.empty? ? 'none' : consoles.join(', ')}); run enroll for it from a real terminal"
    end

    def check_pins!(data, expect)
      unless data['rp_id'].to_s == expect['rp_id'].to_s && !data['rp_id'].to_s.empty?
        raise PinMismatch, "the local rpId pin #{(data['rp_id'] || console_id).to_s.inspect} does not match the authoritative " \
                           "approval_pins.rp_id #{expect['rp_id'].to_s.inspect}"
      end
      return if self.class.key_fingerprint(data['receipt_public_key']) == expect['receipt_key_fingerprint'].to_s

      raise PinMismatch, 'the local receipt key does not match the authoritative approval_pins.receipt_key_fingerprint'
    end

    def decide(code, now, state, entry)
      locked = locked_until(state)
      return Outcome.new(reason: :locked, locked_until: locked) if locked && locked > now
      return Outcome.new(reason: :offline_limit) if offline_limit?(now, state)

      result = Totp.check(seed, code, now: now, last_step: state['last_step'])
      return reject(result.reason, state, now) unless result.ok?

      commit(state, result.step, entry, now)
      Outcome.new(step: result.step)
    end

    def reject(reason, state, now)
      state['failures'] = state['failures'].to_i + 1
      lock_out(state, now) if state['failures'] >= LOCK_AFTER
      write_state(state)
      Outcome.new(reason: reason, locked_until: locked_until(state))
    end

    def lock_out(state, now)
      state['lockouts'] = state['lockouts'].to_i + 1
      state['locked_until'] = (now.utc + lock_seconds(state['lockouts'])).iso8601
      state['failures'] = 0
    end

    def commit(state, step, entry, now)
      state['failures'] = 0
      state['last_step'] = step
      state['locked_until'] = nil
      state['last_sync'] ||= now.utc.iso8601
      append_pending(entry.merge('step' => step, 'at' => now.utc.iso8601)) if entry && console_configured?
      write_state(state)
    end

    def lock_seconds(lockouts) = [ LOCK_BASE * (2**(lockouts - 1)), LOCK_MAX ].min

    # Offline bounds apply only once a console exists: 10 queued entries, or
    # more than 24 h since the last successful sync.
    def offline_limit?(now, state)
      return false unless console_configured?

      last = readable_time(sync_state['last_sync'] || state['last_sync'])
      unsynced.size >= MAX_PENDING || (!last.nil? && now - last > OFFLINE_GRACE)
    end

    def blank_state = { 'last_step' => nil, 'failures' => 0, 'lockouts' => 0, 'locked_until' => nil, 'last_sync' => nil }

    # The counters are the replay fence, so an unreadable state file must never
    # read as a fresh one: it raises and `consume` fails closed.
    def read_state
      data = JSON.parse(File.read(path('totp_state.json')))
      raise JSON::ParserError, 'state is not an object' unless data.is_a?(Hash)

      blank_state.merge(data)
    end

    def write_state(state) = write_atomic(path('totp_state.json'), JSON.pretty_generate(state))

    def locked_until(state) = readable_time(state['locked_until'])

    def readable_time(text)
      text.is_a?(String) ? Time.iso8601(text).utc : nil
    rescue ArgumentError
      nil
    end

    def pending_path = console_file('pending_sync.jsonl') { |file| file }

    def sync_state = console_file('sync_state.json') { |file| read_json(file) } || {}

    # Records a successful contact with the bound console.
    def touch_sync(now)
      console_file('sync_state.json') do |file|
        if file == path('totp_state.json')
          write_state(read_state.merge('last_sync' => now.utc.iso8601))
        elsif File.directory?(File.dirname(file))
          write_atomic(file, JSON.pretty_generate('last_sync' => now.utc.iso8601))
        end
      end
    end

    def append_pending(entry) = write_durable(pending_path, "#{JSON.generate(entry)}\n", File::APPEND)

    def read_lines(file)
      return [] unless File.file?(file)

      File.readlines(file, chomp: true).filter_map { |line| parse_line(line) }
    end

    def parse_line(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def read_json(file)
      data = File.file?(file) ? JSON.parse(File.read(file)) : {}
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def with_lock
      require_enrolled!

      File.open(path('totp.lock'), File::RDWR | File::CREAT, FILE_MODE) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def require_enrolled!
      raise NotEnrolled, 'no TOTP seed is enrolled on this machine' unless enrolled?
    end

    def ensure_dir
      CfSecretStore.ensure_dir(@slug)
      FileUtils.mkdir_p(dir, mode: DIR_MODE)
      File.chmod(DIR_MODE, dir)
    end

    def ensure_console_dir(rp_id)
      [ path('consoles'), File.join(path('consoles'), rp_id) ].each do |sub|
        FileUtils.mkdir_p(sub, mode: DIR_MODE)
        File.chmod(DIR_MODE, sub)
      end
    end

    def legacy?
      return true if File.file?(path('credentials.json'))

      config = read_json(path('console.json'))
      config.key?('base_url') || config.key?('rp_id')
    end

    def migrate_locked
      config = read_json(path('console.json'))
      creds = read_json(path('credentials.json'))
      rp = legacy_rp_id(config, creds)
      move_legacy(rp, config, creds) if rp
      write_atomic(path('console.json'), JSON.pretty_generate(config.except('base_url', 'rp_id')
                                                                    .merge(rp ? { 'default_console' => rp } : {})))
      FileUtils.rm_f(path('credentials.json'))
      rp
    end

    def legacy_rp_id(config, creds)
      host = config['base_url'] ? URI(config['base_url'].to_s).host : nil
      [ creds['rp_id'], config['rp_id'], host ].map(&:to_s).find { |rp| self.class.rp_id?(rp) }
    rescue URI::InvalidURIError
      nil
    end

    def move_legacy(rp_id, config, creds)
      root = File.join(dir, 'consoles', rp_id)
      ensure_console_dir(rp_id)
      write_atomic(File.join(root, 'credentials.json'), JSON.pretty_generate(creds)) unless creds.empty?
      last_sync = read_json(path('totp_state.json'))['last_sync']
      write_atomic(File.join(root, 'sync_state.json'), JSON.pretty_generate('last_sync' => last_sync)) if last_sync
      old = path('pending_sync.jsonl')
      File.rename(old, File.join(root, 'pending_sync.jsonl')) if File.file?(old)
      # console.json last: once it exists the console reads from consoles/<rp_id>/.
      # A retry after an interrupted move finds base_url already gone from the
      # machine config, so keep the one the first pass wrote.
      moved = read_json(File.join(root, 'console.json'))
      base_url = config['base_url'] || moved['base_url']
      write_atomic(File.join(root, 'console.json'), JSON.pretty_generate('base_url' => base_url, 'rp_id' => rp_id))
    end

    # Opens `file` 0600 with `mode` added to WRONLY|CREAT, writes and fsyncs.
    def write_durable(file, content, mode)
      File.open(file, File::WRONLY | File::CREAT | mode, FILE_MODE) do |f|
        f.binmode
        f.write(content)
        f.fsync
      end
    end

    def write_new(file, bytes) = write_durable(file, bytes, File::EXCL)

    def write_atomic(file, content)
      tmp = "#{file}.#{SecureRandom.hex(4)}.tmp"
      write_durable(tmp, content, File::EXCL)
      File.rename(tmp, file)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end
  end
end
