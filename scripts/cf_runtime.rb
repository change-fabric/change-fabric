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
  CHANGE_MODE = 'run /cf:local-only, /cf:merge-ready, /cf:admin-bypass, /cf:yolo, or /cf to change it.'
  # Questions whose default is destructive or puts a real secret at stake, so
  # no safe default exists and they still fire while away.
  FLOOR = [ 'Remote delete', 'Untracked', 'Secret alert', 'Key source' ].freeze

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

      @state.update({ 'mode' => mode }, only_missing: @request['if_unset'] == true)
    when 'availability.set'
      availability = @request['availability']
      raise ArgumentError, 'unknown availability' unless %w[active away].include?(availability)

      @state.update({ 'availability' => availability })
    when 'session.start'
      parent = @request['parent_session_id']
      raise ArgumentError, 'invalid parent session' unless parent.nil? || (parent.is_a?(String) && !parent.empty?)

      initial = @request['initial_mode']
      mode = MergeModeSlug.of(initial)
      raise ArgumentError, 'unknown initial merge mode' if initial && !mode

      @state.update({}, parent: parent, defaults: mode ? { 'mode' => mode } : {})
    else @state.read
    end
    reason = @request['event'] == 'tool.before' ? violation(state) : nil
    { 'version' => 1, 'decision' => reason ? 'deny' : 'allow', 'reason' => reason,
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
    return away_reason(input) if name == 'question' && state['availability'] == 'away'

    action = mode_violation(name, input, state)
    action && "[cf] Merge mode is #{state['mode']}: #{action} is not allowed. " \
              'Run /cf:admin-bypass, /cf:merge-ready, /cf:local-only, /cf:yolo, or /cf to change the mode.'
  end

  def away_reason(input)
    headers = Array(input['questions']).filter_map { |question| question['header'] if question.is_a?(Hash) }
    return unless (headers & FLOOR).empty?

    list = headers.empty? ? '(no header set)' : headers.join(', ')
    "[cf] Away mode is active: this question (#{list}) is not allowed; only #{FLOOR.join(', ')} may ask. " \
      'Take the recommended or safe default and continue; report what was assumed. ' \
      'Run /cf:active to end away mode and resume asking normally.'
  end

  def mode_violation(name, input, state)
    return 'creating a pull request' if name == 'pr.create' && %w[local-only yolo].include?(state['mode'])
    return 'merging a pull request' if name == 'pr.merge' && %w[local-only merge-ready].include?(state['mode'])
    return 'pushing changes' if name == 'git.push' && state['mode'] == 'local-only'
    return 'a direct push to the trunk' if name == 'git.push' && state['mode'] == 'merge-ready' && GuardedCommand::TRUNK.include?(push_target(input))
    return unless name == 'shell'

    command = input['command']
    raise ArgumentError, 'shell command must be a string' unless command.is_a?(String)

    workdir = input['workdir'].is_a?(String) ? File.expand_path(input['workdir'], @request['project']) : @request['project']
    GuardedCommand.new(command, state['mode'], branch: current_branch(workdir)).violation
  end

  # A structured push without an explicit branch pushes the current one.
  def push_target(input)
    branch = input['branch']
    branch.is_a?(String) && !branch.empty? ? branch : current_branch(@request['project'])
  end

  def current_branch(dir)
    branch, = Open3.capture2('git', '-C', dir, 'branch', '--show-current', err: File::NULL)
    branch.strip
  end

  def context(state)
    lines = [ "[cf] Merge mode for this session is #{state['mode']}; availability: #{state['availability']}. " \
              "Honor it per the /cf rules; #{CHANGE_MODE}" ]
    # Claude enforces shell guards through its PreToolUse deny; other hosts may not.
    lines << 'Permissions remain controlled by the host. Shell guards are advisory.' unless @request['host'] == 'claude'
    if state['availability'] == 'away'
      lines << '[cf] Away mode is active for this session. Do not ask questions; take the recommended/safe default ' \
               'and continue; report what was assumed. Run /cf:active to end away mode.'
    end
    lines.join("\n")
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
