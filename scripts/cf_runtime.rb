#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'cf_state'
require_relative 'guarded_command'

# Versioned, host-neutral protocol. Adapters own host event schemas and output.
class CfRuntime
  HOSTS = %w[claude codex copilot opencode pi].freeze
  EVENTS = %w[session.start context mode.set availability.set tool.before tool.after].freeze

  def initialize(request, root: CfState.root, home: Dir.home)
    @request = request
    raise ArgumentError, 'expected protocol version 1' unless request.is_a?(Hash) && request['version'] == 1
    raise ArgumentError, 'unknown host' unless HOSTS.include?(request['host'])
    raise ArgumentError, 'unknown event' unless EVENTS.include?(request['event'])
    raise ArgumentError, 'project must be an absolute directory' unless request['project'].is_a?(String) && request['project'].start_with?('/') && File.directory?(request['project'])
    raise ArgumentError, 'session_id must be a nonempty string' unless request['session_id'].is_a?(String) && !request['session_id'].empty?

    @project = project_root(request['project'])
    @state = CfState.new(host: request['host'], project: @project, session_id: request['session_id'], root: root, home: home)
  end

  def call
    state = case @request['event']
    when 'mode.set'
      mode = MergeModeSlug.of(@request['mode'])
      raise ArgumentError, 'unknown merge mode' unless mode

      @state.update({ 'mode' => mode })
    when 'availability.set'
      availability = @request['availability']
      raise ArgumentError, 'unknown availability' unless %w[active away].include?(availability)

      @state.update({ 'availability' => availability })
    when 'session.start'
      parent = @request['parent_session_id']
      raise ArgumentError, 'invalid parent session' unless parent.nil? || (parent.is_a?(String) && !parent.empty?)

      @state.update({}, parent: parent)
    else @state.read
    end
    violation = @request['event'] == 'tool.before' ? violation(state) : nil
    { 'version' => 1, 'decision' => violation ? 'deny' : 'allow',
      'reason' => violation && "[cf] #{state['mode']}: #{violation} is not allowed",
      'state' => state, 'context' => context(state), 'project' => @project }
  end

  private

  def project_root(path)
    out, status = Open3.capture2('git', '-C', File.realpath(path), 'rev-parse', '--show-toplevel', err: File::NULL)
    status.success? ? File.realpath(out.strip) : File.realpath(path)
  end

  def violation(state)
    tool = @request['tool']
    raise ArgumentError, 'tool must have a name and object input' unless tool.is_a?(Hash) && tool['name'].is_a?(String) && tool['input'].is_a?(Hash)

    name, input = tool.values_at('name', 'input')
    return 'creating a pull request' if name == 'pr.create' && %w[local-only yolo].include?(state['mode'])
    return 'merging a pull request' if name == 'pr.merge' && %w[local-only merge-ready].include?(state['mode'])
    return 'pushing changes' if name == 'git.push' && state['mode'] == 'local-only'
    return 'a direct push to the trunk' if name == 'git.push' && state['mode'] == 'merge-ready' && GuardedCommand::TRUNK.include?(input['branch'])
    return unless name == 'shell'

    command = input['command']
    raise ArgumentError, 'shell command must be a string' unless command.is_a?(String)

    branch, = Open3.capture2('git', '-C', @request['project'], 'branch', '--show-current', err: File::NULL)
    GuardedCommand.new(command, state['mode'], branch: branch.strip).violation
  end

  def context(state)
    "[cf] Merge mode: #{state['mode']}; availability: #{state['availability']}. " \
      'Honor the shared CF workflow. Permissions remain controlled by the host. Shell guards are advisory.'
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    puts JSON.generate(CfRuntime.new(JSON.parse($stdin.read)).call)
  rescue JSON::ParserError, ArgumentError, SystemCallError => e
    warn "[cf] runtime error: #{e.message}"
    puts JSON.generate('version' => 1, 'decision' => 'error', 'error' => e.message)
    exit 1
  end
end
