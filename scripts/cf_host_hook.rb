#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'stringio'
require_relative 'cf_runtime'
require_relative 'skill_compiler'
require_relative 'skill_detect'
require_relative 'skill_inject'
require_relative 'skill_review'
require_relative 'merge_mode_answer'
require_relative 'away_answer'
require_relative 'slop_remind'

# Native wire-format adapter. No host-specific mode policy belongs here.
class CfHostHook
  EVENTS = { 'SessionStart' => 'session.start', 'SubagentStart' => 'session.start',
             'UserPromptSubmit' => 'context', 'PostCompact' => 'context',
             'PreToolUse' => 'tool.before', 'PostToolUse' => 'tool.after', 'Stop' => 'context' }.freeze
  COPILOT_EVENTS = { 'sessionStart' => 'SessionStart', 'subagentStart' => 'SubagentStart',
                     'userPromptSubmitted' => 'UserPromptSubmit', 'preToolUse' => 'PreToolUse',
                     'postToolUse' => 'PostToolUse', 'agentStop' => 'Stop' }.freeze
  # Interview skills whose judgment calls must come from the human.
  PLAN = %r{\A\s*(?:\$cf-|/cf:|/skill:cf-)(plan|drive(?:\s+thorough)?\b(?!\s+quick\b))\b}
  # Events where the session state is restated; elsewhere it would only add noise per tool call.
  CONTEXT_EVENTS = %w[SessionStart SubagentStart UserPromptSubmit PostCompact].freeze
  MODE = /\A\s*(?:\$cf-|\/cf:|\/skill:cf-)(local-only|merge-ready|admin-bypass|yolo|active|away)(?=\s|$)/

  def initialize(host:, event:, payload:, root: CfState.root, home: Dir.home, skills: nil)
    raise ArgumentError, 'invalid hook payload' unless payload.is_a?(Hash)

    @host = host
    @event = COPILOT_EVENTS.fetch(event, event)
    raise ArgumentError, 'unknown hook event' unless EVENTS.key?(@event)

    @payload, @root, @home = payload, root, home
    @skills = skills || SkillRegistry.load(File.join(home, '.local/share/change-fabric/source-skills'))
    @compiler = SkillCompiler.new(host: host)
  end

  def call
    request = base.merge('event' => EVENTS.fetch(@event))
    request['tool'] = tool if %w[PreToolUse PostToolUse].include?(@event)
    request['parent_session_id'] = parent_id if @event == 'SubagentStart' && parent_id
    result = runtime(request)
    @resolved_project = result['project']
    result = apply_mode(request) || result if @event == 'UserPromptSubmit' || @event == 'SessionStart'
    result = record_choice(request) || result if @event == 'PostToolUse'
    restate = CONTEXT_EVENTS.include?(@event) || result['decision'] == 'deny'
    contexts = [ @confirmation, (result.fetch('context') if restate), plan_refusal(result) ].compact
    @rubrics = rubric_contexts
    contexts.concat(@rubrics)
    review = review_result
    if review['decision'] == 'block'
      review['reason'] = @compiler.references(review['reason']).sub(/Agent\(subagent_type: "general-purpose", model: "haiku", run_in_background: false\)/,
        'Use the host-native reviewer or review the files directly when delegation is unavailable')
      return review
    end

    contexts << review['systemMessage'] if review['systemMessage']
    output(result, @compiler.references(contexts.join("\n\n")))
  end

  private

  def plan_refusal(result)
    return unless @event == 'UserPromptSubmit' && result.dig('state', 'availability') == 'away'

    match = (@payload['prompt'] || @payload['initialPrompt']).to_s.match(PLAN)
    return unless match

    skill = "cf:#{match[1].split.join(' ')}"
    "[cf] Away mode is active: refuse to start the #{skill} interview. Guessing its judgment calls " \
      "defeats the point of running it. Tell the user to run /cf:active first, then re-run /#{skill}."
  end

  def runtime(request) = CfRuntime.new(request, root: @root, home: @home).call

  def base
    { 'version' => 1, 'host' => @host, 'project' => @payload['cwd'], 'session_id' => session_id }
  end

  def session_id
    root = @payload['session_id'] || @payload['sessionId']
    raise ArgumentError, 'missing native session id' unless root.is_a?(String) && !root.empty?

    agent = @payload['agent_id'] || @payload['agentId']
    agent ? "#{root}:#{agent}" : root
  end

  def parent_id
    root = @payload['session_id'] || @payload['sessionId']
    parent = @payload['parent_agent_id'] || @payload['parentAgentId']
    return "#{root}:#{parent}" if parent
    return root if @payload['agent_id'] || @payload['agentId']

    @payload['parent_session_id']
  end

  def tool
    name = @payload['tool_name'] || @payload['toolName']
    input = @payload['tool_input'] || @payload['toolArgs'] || {}
    input = JSON.parse(input) if input.is_a?(String)
    raise ArgumentError, 'invalid native tool input' unless name.is_a?(String) && input.is_a?(Hash)

    canonical = case name
    when 'Bash', 'bash', 'exec_command', 'shell_command', 'shell' then 'shell'
    when 'AskUserQuestion', 'ask_user', 'request_user_input', 'request_user_input_async' then 'question'
    when /(?:__github_|^)(?:create_pull_request)$/ then 'pr.create'
    when /(?:__github_|^)(?:merge_pull_request)$/ then 'pr.merge'
    else name
    end
    input = input.merge('command' => input['command'] || input['cmd']) if canonical == 'shell'
    { 'name' => canonical, 'input' => input }
  end

  def apply_mode(request)
    prompt = @payload['prompt'] || @payload['initialPrompt'] || @payload['initial_prompt']
    match = prompt.to_s.match(MODE)
    return unless match

    default = @payload['cf_default'] == true
    result = set_choice(request, match[1], if_unset: default)
    @confirmation = confirmation(match[1]) unless default
    result
  end

  def confirmation(choice)
    case choice
    when 'away'
      '[cf] Away mode is now on for this session. Do not ask questions; take the recommended/safe default and continue. Run /cf:active to end away mode.'
    when 'active'
      '[cf] Away mode is now off for this session. Ask normally again. Run /cf:away to step away.'
    else
      "[cf] Merge mode for this session is now #{choice}. Honor it per the /cf rules; #{CfRuntime::CHANGE_MODE}"
    end
  end

  def set_choice(request, choice, if_unset: false)
    if %w[active away].include?(choice)
      runtime(request.merge('event' => 'availability.set', 'availability' => choice))
    else
      runtime(request.merge('event' => 'mode.set', 'mode' => choice, 'if_unset' => if_unset))
    end
  end

  def record_choice(request)
    return unless successful_tool?

    native = @payload['tool_name'] || @payload['toolName']
    if %w[skill Skill].include?(native)
      mode = tool['input']['name'].to_s[/\Acf[:-](local-only|merge-ready|admin-bypass|yolo|away|active)\z/, 1]
      return set_choice(request, mode) if mode
    end
    return unless tool['name'] == 'question'

    response = @payload['tool_response'] || @payload['toolResult']
    mode = MergeModeAnswer.new(response).label
    result = set_choice(request, mode) if MergeModeSlug.of(mode)
    away = AwayAnswer.new(response).label
    # A free-form answer is not an explicit request to stay away.
    result = set_choice(request, away.to_s.strip.downcase == 'away' ? 'away' : 'active') if away
    result
  end

  def successful_tool?
    return false if @payload['isError'] || @payload['is_error']

    result = @payload['tool_response'] || @payload['toolResult']
    !result.is_a?(Hash) || !(result['isError'] || result['is_error'] || result['resultType'] == 'failure')
  end

  # Reuse deterministic rubric selection. Legacy review stores receive an
  # opaque host/project/session key so concurrent hosts never share a queue.
  def legacy_event
    key = Digest::SHA256.hexdigest([ @host, @resolved_project || File.realpath(@payload.fetch('cwd')), session_id ].join("\0"))
    @payload.merge('session_id' => "cf-#{key}", 'tool_name' => @payload['tool_name'] || @payload['toolName'])
  end

  def capture(handler)
    io = StringIO.new
    handler.emit(io)
    io.string.empty? ? {} : JSON.parse(io.string)
  end

  def rubric_contexts
    return [] if @host == 'claude' # existing native rubric hooks remain wired

    event = legacy_event
    if @event == 'PreToolUse' && tool['name'] == 'shell'
      event = event.merge('tool_name' => 'Bash', 'tool_input' => tool['input'])
      return [ capture(SlopRemind.new(event, skills: @skills)).dig('hookSpecificOutput', 'additionalContext') ].compact
    end
    if @event == 'SessionStart'
      return [ capture(SkillDetect.new(event, skills: @skills)).dig('hookSpecificOutput', 'additionalContext') ].compact
    end
    return [] unless @event == 'PostToolUse' && successful_tool?

    input = tool['input']
    name = event['tool_name']
    paths = if name == 'apply_patch'
      (input['command'] || input['patch'] || '').scan(/^\*\*\* (?:Add|Update) File: (.+)$/).flatten
    elsif %w[Edit Write MultiEdit edit write create str_replace_editor].include?(name)
      [ input['file_path'] || input['path'] || input['filePath'] ].compact
    else []
    end
    paths.filter_map do |path|
      normalized = event.merge('tool_name' => 'Edit', 'tool_input' => { 'file_path' => File.expand_path(path, @payload.fetch('cwd')) })
      capture(SkillInject.new(normalized, skills: @skills)).dig('hookSpecificOutput', 'additionalContext')
    end
  end

  def review_result
    return {} unless @event == 'Stop' && @host != 'claude'

    capture(SkillReview.new(legacy_event, skills: @skills))
  end

  def output(result, context)
    context = nil if context.empty?
    if @host == 'copilot'
      return { 'permissionDecision' => 'deny', 'permissionDecisionReason' => result['reason'] } if result['decision'] == 'deny'
      return {} if @event == 'UserPromptSubmit' || context.nil? # command-hook output is ignored by Copilot

      return { 'additionalContext' => context }
    end
    specific = { 'hookEventName' => @event }
    specific['additionalContext'] = context if context
    # Hosts that cannot inject context mid-call surface a rubric by blocking once.
    specific['rubricContext'] = @compiler.references(@rubrics.join("\n\n")) if @event == 'PreToolUse' && @rubrics.any?
    specific.merge!('permissionDecision' => 'deny', 'permissionDecisionReason' => result['reason']) if result['decision'] == 'deny'
    specific.size == 1 ? {} : { 'hookSpecificOutput' => specific }
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    host, event = ARGV
    puts JSON.generate(CfHostHook.new(host: host, event: event, payload: JSON.parse($stdin.read)).call)
  rescue StandardError => e
    # Hooks fail silent. Denying on an internal error would wedge every tool,
    # including the shell the agent needs to recover from a deleted cwd.
    warn "[cf] adapter error: #{e.message}"
    puts '{}'
  end
end
