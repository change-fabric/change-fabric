# frozen_string_literal: true

require 'digest'
require 'json'
require 'fileutils'
require 'tempfile'
require_relative 'merge_mode_slug'

# Host/project/session identities are hashed, never interpolated into paths.
# A lock serializes read-modify-write across processes; rename makes reads atomic.
class CfState
  def self.root(home: Dir.home)
    ENV['CF_STATE_HOME'].to_s.empty? ? File.join(home, '.local', 'state', 'change-fabric') : File.expand_path(ENV.fetch('CF_STATE_HOME'))
  end

  def initialize(host:, project:, session_id:, root: self.class.root, home: Dir.home)
    raise ArgumentError, 'session_id is required' if session_id.to_s.empty?

    @host, @project, @session_id = host, File.realpath(project), session_id
    @root, @home = root, home
    @project_key = Digest::SHA256.hexdigest(@project)
  end

  def read
    locked { effective(@session_id) }
  end

  def update(values, parent: nil)
    locked do
      data = own(@session_id)
      if parent
        raise ArgumentError, 'session cannot inherit itself' if parent == @session_id
        raise ArgumentError, 'parent binding cannot change' if data['parent'] && data['parent'] != parent

        effective(parent, [ @session_id ]) # reject cycles before persisting
        data['parent'] = parent
      end
      data.merge!(values)
      write(data)
      effective(@session_id)
    end
  end

  private

  def locked
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.open(File.join(directory, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def directory = File.join(@root, 'sessions', @host, @project_key)
  def path(id) = File.join(directory, "#{Digest::SHA256.hexdigest(id)}.json")

  def own(id)
    return {} unless File.file?(path(id))

    data = JSON.parse(File.read(path(id)))
    raise ArgumentError, 'invalid persisted session state' unless data.is_a?(Hash) && data['version'] == 1

    data
  end

  def effective(id, seen = [])
    raise ArgumentError, 'cyclic or excessive session ancestry' if seen.include?(id) || seen.length >= 32

    data = own(id)
    inherited = data['parent'] ? effective(data['parent'], seen + [ id ]) : {}
    mode = data['mode'] || inherited['mode'] || legacy_mode(id)
    { 'mode' => MergeModeSlug.of(mode) || MergeModeSlug::FALLBACK,
      'availability' => data['availability'] || inherited['availability'] || 'active' }
  end

  # Read-only compatibility import. Neutral state always takes precedence;
  # another host's legacy state is never considered.
  def legacy_mode(id)
    return unless @host == 'claude' && id.match?(/\A[\w-]+\z/)

    file = File.join(@home, '.claude', 'cf', 'sessions', id, 'merge-mode')
    File.file?(file) ? MergeModeSlug.of(File.read(file)) : nil
  end

  def write(data)
    Tempfile.create([ '.session-', '.json' ], directory) do |file|
      file.chmod(0o600)
      file.write(JSON.generate(data.merge('version' => 1)))
      file.flush
      file.fsync
      File.rename(file.path, path(@session_id))
    end
  end
end
