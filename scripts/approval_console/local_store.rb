# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'openssl'
require 'securerandom'
require 'socket'
require 'time'
require_relative '../cf_secret_store'
require_relative 'totp'

module ApprovalConsole
  # The terminal path's protected state, kept under the cf secret store at
  # ~/.claude/cf/secrets/<machine slug>/approval/ (0700 dirs, 0600 files, read
  # denied to agent tools by secrets_read_guard.rb): the TOTP seed, the
  # fencing and lockout counters, the machine id and the offline sync queue.
  # No OS keychain API and no platform branch. Every read, check and write of
  # the counters runs under an exclusive flock on a stable lock file and is
  # fsynced before the lock is released. Only `enroll!` and `seed` ever return
  # the seed, and nothing here logs it.
  class LocalStore
    class NotEnrolled < StandardError; end
    class AlreadyEnrolled < StandardError; end

    FILE_MODE = 0o600
    DIR_MODE = 0o700
    SEED_BYTES = 20
    LOCK_AFTER = 5
    LOCK_BASE = 900
    LOCK_MAX = 86_400
    OFFLINE_GRACE = 86_400
    MAX_PENDING = 10

    Outcome = Struct.new(:reason, :step, :locked_until, keyword_init: true) do
      def ok? = reason.nil?
    end

    # One slug per machine: a fixed-length hash of the host name, one path segment.
    def self.machine_slug(host = Socket.gethostname) = Digest::SHA256.hexdigest("machine:#{host}")[0, 32]

    attr_reader :slug

    def initialize(slug: self.class.machine_slug)
      @slug = slug
    end

    def dir = File.join(CfSecretStore.dir(@slug), 'approval')

    def path(name) = File.join(dir, name)

    def enrolled? = File.file?(path('totp_seed'))

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
      FileUtils.rm_f(Dir.glob(File.join(dir, '*')))
    end

    def seed
      require_enrolled!

      File.binread(path('totp_seed'))
    end

    def console = read_json(path('console.json'))

    def machine_id = console['machine_id']

    def label = console['label']

    # Without a console URL the local fence is the only channel.
    def console_configured? = !console['base_url'].to_s.empty?

    def base_url = console['base_url']

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

    # Pins the console for this machine: base URL and rpId in console.json, the
    # passkey public keys and the receipt public key in credentials.json.
    def pin!(base_url:, rp_id:, credentials:, receipt_public_key:, receipt_key_id:)
      require_enrolled!
      write_atomic(path('credentials.json'), JSON.pretty_generate(
                                               'rp_id' => rp_id, 'credentials' => credentials,
                                               'receipt_public_key' => receipt_public_key, 'receipt_key_id' => receipt_key_id
                                             ))
      write_atomic(path('console.json'), JSON.pretty_generate(console.merge('base_url' => base_url, 'rp_id' => rp_id)))
    end

    # { 'rp_id', 'credentials' => {id => cose}, 'receipt_public_key' } or {}.
    def pins = read_json(path('credentials.json'))

    # Raises the local fence mirror to a step the console accepted, and records
    # a successful console contact for the offline bounds.
    def observe_step(step, now: Time.now)
      with_lock do
        state = read_state
        state['last_step'] = [ state['last_step'], step ].compact.max
        state['last_sync'] = now.utc.iso8601
        write_state(state)
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
        write_atomic(path('pending_sync.jsonl'), entries.map { |entry| "#{JSON.generate(entry)}\n" }.join)
        state = read_state
        state['last_sync'] = now.utc.iso8601 if status == :synced
        write_state(state)
      end
    end

    # Request bodies this machine sent with `request --no-wait`, for `wait`.
    def save_request(request_id, body)
      FileUtils.mkdir_p(path('requests'), mode: DIR_MODE)
      write_atomic(File.join(path('requests'), "#{request_id}.json"), body)
    end

    def saved_request(request_id)
      return nil unless request_id.to_s.match?(/\A[0-9a-f-]{36}\z/)

      file = File.join(path('requests'), "#{request_id}.json")
      File.file?(file) ? File.read(file) : nil
    end

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
        pending: unsynced.size, conflicts: conflicts.size, console_configured: console_configured? }
    end

    def pending = read_lines(path('pending_sync.jsonl'))

    def conflicts = pending.select { |entry| entry['status'] == 'conflict' }

    # Queued offline approvals still waiting for a console receipt.
    def unsynced = pending.reject { |entry| entry['status'] == 'conflict' }

    private

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

      last = readable_time(state['last_sync'])
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

    def append_pending(entry)
      File.open(path('pending_sync.jsonl'), File::WRONLY | File::CREAT | File::APPEND, FILE_MODE) do |file|
        file.write("#{JSON.generate(entry)}\n")
        file.fsync
      end
    end

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

    def write_new(file, bytes)
      File.open(file, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) do |f|
        f.binmode
        f.write(bytes)
        f.fsync
      end
    end

    def write_atomic(file, content)
      tmp = "#{file}.#{SecureRandom.hex(4)}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) do |f|
        f.write(content)
        f.fsync
      end
      File.rename(tmp, file)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end
  end
end
