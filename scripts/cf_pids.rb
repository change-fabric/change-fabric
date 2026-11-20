# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'

# Registry of dev servers a cf session launched, so tier-1 reclaim can stop its
# own strays and nothing else. An entry is {pid, start_time, command}; a process
# is stopped only when the live PID, its start time (ps -o lstart=) and its
# command all match, so a reused PID is never killed. Never pkill -f.
class CfPids
  # Reads one live process: {start_time:, command:} or nil when it is gone.
  class PsTable
    def read(pid)
      start, ok = capture('ps', '-o', 'lstart=', '-p', pid.to_s)
      return nil unless ok && !start.strip.empty?

      command, = capture('ps', '-o', 'command=', '-p', pid.to_s)
      { start_time: start.strip, command: command.strip }
    end

    private

    def capture(*cmd)
      out, status = Open3.capture2e(*cmd)
      [ out, status.success? ]
    rescue SystemCallError
      [ '', false ]
    end
  end

  def self.default_root = File.join(Dir.home, '.claude', 'cf')

  def initialize(session:, root: self.class.default_root, table: PsTable.new, killer: Process.method(:kill))
    raise ArgumentError, 'session is required' if session.to_s.empty?

    @dir = File.join(root, 'sessions', segment(session))
    @table = table
    @killer = killer
  end

  def path = File.join(@dir, 'pids.json')

  def entries = locked { load }

  # Records a live process. start_time and command default to what ps reports.
  def register(pid:, command: nil, start_time: nil)
    live = @table.read(pid)
    start_time ||= live&.fetch(:start_time)
    command ||= live&.fetch(:command)
    raise ArgumentError, "pid #{pid} is not running" unless start_time && command

    entry = { 'pid' => Integer(pid), 'start_time' => start_time, 'command' => command }
    locked do
      list = load.reject { |e| e['pid'] == entry['pid'] }
      save(list << entry)
    end
    entry
  end

  # Entries whose live process still matches on PID, start time and command.
  def live_matches
    entries.select { |e| match?(e) }
  end

  # Signals every matching entry, drops those stopped or gone, returns the PIDs
  # stopped. A mismatched entry (a reused PID) is dropped and never signaled.
  def stop_matching(signal: 'TERM')
    stopped = []
    locked do
      keep = load.reject do |entry|
        live = @table.read(entry['pid'])
        stopped << entry['pid'] if match?(entry, live) && signal_pid(entry['pid'], signal)
        true
      end
      save(keep)
    end
    stopped
  end

  private

  def signal_pid(pid, signal)
    @killer.call(signal, pid)
    true
  rescue SystemCallError
    false
  end

  def match?(entry, live = @table.read(entry['pid']))
    live && live[:start_time] == entry['start_time'] && live[:command] == entry['command']
  end

  # A session id is hashed unless it is already a safe path segment.
  def segment(session)
    session.to_s.match?(/\A[A-Za-z0-9._-]{1,128}\z/) && !session.to_s.start_with?('.') ? session.to_s : Digest::SHA256.hexdigest(session.to_s)
  end

  def locked
    FileUtils.mkdir_p(@dir, mode: 0o700)
    File.open(File.join(@dir, 'pids.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def load
    data = JSON.parse(File.read(path))
    data.is_a?(Array) ? data.select { |e| e.is_a?(Hash) && e['pid'].is_a?(Integer) } : []
  rescue SystemCallError, JSON::ParserError
    []
  end

  def save(list)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(list), perm: 0o600)
    File.rename(tmp, path)
    list
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { session: ENV.fetch('CF_SESSION_ID', nil) }
  parser = OptionParser.new do |o|
    o.banner = 'usage: cf_pids.rb register|list --session ID [--pid N] [--command CMD]'
    o.on('--session ID') { |v| opts[:session] = v }
    o.on('--pid N', Integer) { |v| opts[:pid] = v }
    o.on('--command CMD') { |v| opts[:command] = v }
  end
  verb = parser.parse!(ARGV).shift
  begin
    registry = CfPids.new(session: opts[:session])
    case verb
    when 'register' then puts JSON.generate(registry.register(pid: opts.fetch(:pid), command: opts[:command]))
    when 'list' then puts JSON.generate(registry.entries)
    else abort(parser.banner)
    end
  rescue ArgumentError, KeyError, OptionParser::ParseError => e
    warn "cf_pids: #{e.message}"
    exit 2
  end
end
