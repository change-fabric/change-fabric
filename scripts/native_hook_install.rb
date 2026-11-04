# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'shellwords'

# Modify only our exact command entries; never replace another hook definition.
class NativeHookInstall
  EVENTS = %w[SessionStart UserPromptSubmit PreToolUse PostToolUse SubagentStart Stop].freeze
  COPILOT = { 'SessionStart' => 'sessionStart', 'UserPromptSubmit' => 'userPromptSubmitted',
              'PreToolUse' => 'preToolUse', 'PostToolUse' => 'postToolUse',
              'SubagentStart' => 'subagentStart', 'Stop' => 'agentStop' }.freeze

  def initialize(path:, host:, ruby:, bin:, backup: true)
    @path, @host, @ruby, @bin = path, host, ruby, bin
    @backup = backup
  end

  def wire
    data = File.file?(@path) ? JSON.parse(File.read(@path)) : {}
    raise ArgumentError, "invalid hook config: #{@path}" unless data.is_a?(Hash)

    hooks = data['hooks'] ||= {}
    raise ArgumentError, "invalid hooks in #{@path}" unless hooks.is_a?(Hash)

    EVENTS.each do |event|
      next if @host == 'claude' && event == 'Stop'

      key = @host == 'copilot' ? COPILOT.fetch(event) : event
      entries = hooks[key] ||= []
      raise ArgumentError, "invalid #{key} hooks" unless entries.is_a?(Array)

      command = Shellwords.join([ @ruby, File.join(@bin, 'cf_host_hook.rb'), @host, event ])
      if @host == 'copilot'
        entries.reject! { |entry| entry.is_a?(Hash) && managed_command?(entry['bash']) }
        entries << { 'type' => 'command', 'bash' => command, 'timeoutSec' => 5 }
      else
        entries.each do |group|
          next unless group.is_a?(Hash) && group['hooks'].is_a?(Array)

          group['hooks'].reject! { |hook| hook.is_a?(Hash) && managed_command?(hook['command']) }
        end
        entries.reject! { |group| group.is_a?(Hash) && group['hooks'] == [] }
        entries << { 'hooks' => [ { 'type' => 'command', 'command' => command, 'timeout' => 5 } ] }
      end
    end
    data['version'] = 1 if @host == 'copilot'
    FileUtils.mkdir_p(File.dirname(@path))
    FileUtils.cp(@path, "#{@path}.bak") if @backup && File.file?(@path)
    File.write("#{@path}.tmp", "#{JSON.pretty_generate(data)}\n")
    File.rename("#{@path}.tmp", @path)
  end

  def unwire
    return unless File.file?(@path)

    data = JSON.parse(File.read(@path))
    data.fetch('hooks', {}).each_value do |entries|
      next unless entries.is_a?(Array)

      if @host == 'copilot'
        entries.reject! { |entry| entry.is_a?(Hash) && managed_command?(entry['bash']) }
      else
        entries.each do |group|
          next unless group.is_a?(Hash) && group['hooks'].is_a?(Array)

          group['hooks'].reject! { |hook| hook.is_a?(Hash) && managed_command?(hook['command']) }
        end
        entries.reject! { |group| group.is_a?(Hash) && group['hooks'] == [] }
      end
    end
    FileUtils.cp(@path, "#{@path}.bak")
    File.write("#{@path}.tmp", JSON.pretty_generate(data) + "\n")
    File.rename("#{@path}.tmp", @path)
  end

  private

  def managed_command?(command)
    words = Shellwords.split(command.to_s)
    words[1] == File.join(@bin, 'cf_host_hook.rb') && words[2] == @host
  rescue ArgumentError
    false
  end
end
