# frozen_string_literal: true

require 'json'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'cf_provider_registry'

# The Codex CLI critic backend for cf:roast: one `codex exec` call under the
# user's ChatGPT subscription instead of a metered API call. Only the official
# CLI is used; tokens in ~/.codex/auth.json are never read, and the child env is
# scrubbed so codex cannot silently switch to API-key auth. Pure of roast.rb: the
# caller hands in the schema and the validator.
module RoastCodex
  DEFAULT_COMMAND = %w[codex].freeze
  COMMAND_ENV = 'CF_ROAST_CODEX'
  TIMEOUT_ENV = 'CF_ROAST_CODEX_TIMEOUT'
  SENTINEL_ENV = 'CF_ROAST_CRITIC'
  DEFAULT_TIMEOUT = 300
  PROBE_TIMEOUT = 30
  KILL_GRACE = 5
  PROMPT_DELIMITER = "\n\n=====\n\n"
  LOGGED_IN = /\ALogged in using ChatGPT\b/
  NOT_LOGGED_IN = /\ANot logged in\b/
  SCRUBBED = %w[OPENAI_API_KEY CODEX_API_KEY].freeze
  SECRET_NAME = /KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/
  # Error-event codes that mean the subscription is out of room. Drift in these
  # strings fails the round by name rather than broadening the match.
  LIMIT_CODES = %w[usage_limit_reached rate_limit_reached workspace_owner_credits_depleted
                   workspace_member_credits_depleted workspace_owner_usage_limit_reached
                   workspace_member_usage_limit_reached credits_depleted].freeze
  # One ranking, strongest first, shared by every tier. It is pinned so scores are
  # reproducible across machines; it is the definition of strongest.
  MODEL_RANK = %w[gpt-6.2-sol gpt-6.2-astra gpt-6.1-sol gpt-6.1-terra gpt-6-sol gpt-6-astra gpt-6-luna
                  gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex gpt-5.2].freeze
  # The tier only breaks ties and sets effort; it never narrows the list.
  TIERS = { 'sol' => { prefer: 'sol', effort: 'high' }, 'terra' => { prefer: 'terra', effort: 'medium' } }.freeze
  # A model that is rejected costs no quota; roast tries this many more.
  EXTRA_MODEL_ATTEMPTS = 2
  # Codex takes low through xhigh; roast's wider scale is clamped onto it.
  EFFORT_CLAMP = { 'none' => 'low', 'max' => 'xhigh' }.freeze
  MODEL_REJECTED = /not supported when using Codex with a ChatGPT account|requires a newer version of Codex/

  # Base class so a caller can rescue every codex-backend outcome at once.
  class Error < StandardError
    attr_reader :reason

    def initialize(reason, detail = nil)
      @reason = reason
      super("roast: codex #{reason.to_s.tr('_', ' ')}#{detail ? ": #{detail}" : ''}")
    end
  end
  # Fallback-eligible: missing, not_logged_in, no_vision_model, limit.
  class Unavailable < Error; end
  # Never falls back: schema, timeout, crash, probe.
  class Failed < Error; end
  # The server refused the model (400 model_not_found, not supported on a
  # ChatGPT account, needs a newer CLI). Costs no quota; the caller may try the
  # next ranked model.
  class Rejected < Error; end

  Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out, keyword_init: true)
  Answer = Struct.new(:critic, :usage, keyword_init: true) do
    # Input plus output tokens of the turn, nil when the stream carried no usage.
    def subscription_tokens
      return nil unless usage.is_a?(Hash)

      usage.values_at('input_tokens', 'output_tokens').compact.sum
    end
  end

  module_function

  def command(env = ENV)
    configured = env[COMMAND_ENV].to_s.strip
    configured.empty? ? DEFAULT_COMMAND : Shellwords.split(configured)
  end

  def timeout_for(env = ENV)
    n = Integer(env[TIMEOUT_ENV].to_s, exception: false)
    n&.positive? ? n : DEFAULT_TIMEOUT
  end

  # The env a critic child sees: no API-key auth, no cf secrets, the sentinel
  # that keeps cf hooks from firing inside the call.
  def child_env(env = ENV, registry: CfProviderRegistry)
    drop = SCRUBBED + scrubbed_provider_names(registry)
    kept = env.to_h.reject { |k, _| drop.include?(k) || (k.start_with?('CF_') && k.match?(SECRET_NAME)) }
    kept.merge(SENTINEL_ENV => '1')
  end

  def scrubbed_provider_names(registry)
    registry.all.flat_map(&:ignored_env) + registry.global_ignored_env
  rescue StandardError
    []
  end

  # `[:ok]`, `[:unavailable, :missing | :not_logged_in]`, or `[:error, detail]`.
  # Only :unavailable may fall back; the caller raises Failed(:probe) on :error.
  def available?(runner: method(:run_process), env: ENV)
    result = runner.call([ *command(env), 'login', 'status' ], env: child_env(env), stdin: '', timeout: PROBE_TIMEOUT, chdir: nil)
    return [ :error, 'login status timed out' ] if result.timed_out

    text = "#{result.stdout}#{result.stderr}".strip
    return [ :ok ] if result.exit_code.zero? && text.match?(LOGGED_IN)
    return [ :unavailable, :not_logged_in ] if text.match?(NOT_LOGGED_IN)

    [ :error, "unexpected login status (exit #{result.exit_code}): #{text[0, 120].inspect}" ]
  rescue Errno::ENOENT, Errno::EACCES
    [ :unavailable, :missing ]
  rescue StandardError => e
    [ :error, "login status probe crashed: #{e.class}" ]
  end

  # Like available?, but raises: Unavailable for the fallback-eligible answers,
  # Failed(:probe) for the rest.
  def ensure_available!(**opts)
    status, detail = available?(**opts)
    return if status == :ok
    raise Unavailable.new(detail) if status == :unavailable

    raise Failed.new(:probe, detail)
  end

  # Vision-capable, user-listed model slugs from `codex debug models` (the live
  # catalog the CLI itself resolves against). Raises Failed(:probe) when the
  # catalog cannot be read.
  def live_models(runner: method(:run_process), env: ENV)
    result = runner.call([ *command(env), 'debug', 'models' ], env: child_env(env), stdin: '', timeout: PROBE_TIMEOUT, chdir: nil)
    raise Failed.new(:probe, 'model list timed out') if result.timed_out
    raise Failed.new(:probe, "model list exited #{result.exit_code}") unless result.exit_code.zero?

    JSON.parse(result.stdout).fetch('models').select do |m|
      m['visibility'] == 'list' && Array(m['input_modalities']).include?('image')
    end.map { |m| m['slug'] }
  rescue JSON::ParserError, KeyError, TypeError
    raise Failed.new(:probe, 'model list was not the expected JSON')
  rescue Errno::ENOENT, Errno::EACCES
    raise Unavailable.new(:missing)
  end

  # The tier a roast model name belongs to (gpt-6.1-sol is sol), or nil.
  def tier_for(model) = TIERS.keys.find { |t| model.to_s.end_with?("-#{t}") }

  # Every vision model, strongest first. Ranked models lead in MODEL_RANK
  # order; the tier's suffix only orders models of equal rank, and unranked
  # ones sort last.
  def rank(models, tier: nil)
    prefer = TIERS.dig(tier, :prefer)
    models.sort_by { |m| [ MODEL_RANK.index(m) || MODEL_RANK.size, prefer && m.end_with?("-#{prefer}") ? 0 : 1, m ] }
  end

  def unranked(models) = models.reject { |m| MODEL_RANK.include?(m) }

  def clamp_effort(effort) = EFFORT_CLAMP.fetch(effort.to_s, effort.to_s)

  def build_argv(model:, effort:, images:, schema_path:, out_path:, dir:, command: DEFAULT_COMMAND)
    [ *command, 'exec', *images.flat_map { |i| [ '-i', i ] },
      '--json', '-s', 'read-only', '--ephemeral', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules',
      '-C', dir, '-m', model, '-c', "model_reasoning_effort=#{effort}",
      '--output-schema', schema_path, '-o', out_path, '-' ]
  end

  def prompt(system:, user:) = "#{system}#{PROMPT_DELIMITER}#{user}"

  # One critic call. Returns an Answer or raises Unavailable, Rejected, or Failed.
  def call(system:, user:, images:, model:, effort:, schema:, validate:, runner: method(:run_process), env: ENV, timeout: nil)
    Dir.mktmpdir('roast-codex') do |tmp|
      work = File.join(tmp, 'work')
      Dir.mkdir(work)
      schema_path = File.join(tmp, 'schema.json')
      out_path = File.join(tmp, 'last.json')
      File.write(schema_path, JSON.generate(schema))
      # The child runs in an empty directory, so a relative path must be
      # resolved against the caller's directory first.
      argv = build_argv(model: model, effort: effort, images: images.map { |i| File.expand_path(i) }, schema_path: schema_path, out_path: out_path,
                        dir: work, command: command(env))
      result = runner.call(argv, env: child_env(env), stdin: prompt(system: system, user: user),
                                 timeout: timeout || timeout_for(env), chdir: work)
      raise Failed.new(:timeout, "no answer within #{timeout || timeout_for(env)}s") if result.timed_out

      classify(result, out_path, validate)
    end
  rescue Errno::ENOENT, Errno::EACCES
    raise Unavailable.new(:missing)
  end

  # The --json event stream, one object per line. Lines that are not JSON
  # objects with a type are ignored.
  def parse_events(stdout)
    stdout.to_s.lines.filter_map do |line|
      event = JSON.parse(line)
      event if event.is_a?(Hash) && event['type']
    rescue JSON::ParserError
      nil
    end
  end

  def error_events(events) = events.select { |e| %w[error turn.failed].include?(e['type']) }

  # The server's error body inside an event, or nil when it is not JSON.
  def error_body(event)
    raw = event['type'] == 'turn.failed' ? event.dig('error', 'message') : event['message']
    parsed = JSON.parse(raw.to_s)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def limit_event?(event)
    body = error_body(event)
    codes = body ? [ body.dig('error', 'type'), body.dig('error', 'code'), body['type'] ] : []
    return codes.any? { |c| LIMIT_CODES.include?(c) } if body

    LIMIT_CODES.any? { |c| (event['message'] || event.dig('error', 'message')).to_s.include?(c) }
  end

  def rejected_event?(event)
    body = error_body(event)
    return false unless body && body['status'] == 400

    body.dig('error', 'code') == 'model_not_found' || body.dig('error', 'message').to_s.match?(MODEL_REJECTED)
  end

  # Precedence: limit, rejected model, other error event or non-zero exit,
  # no turn.completed, then the answer file's schema validity. A limit comes only
  # from an error event, never from the critic's text or stderr.
  def classify(result, out_path, validate)
    events = parse_events(result.stdout)
    errors = error_events(events)
    raise Unavailable.new(:limit, 'subscription usage limit reached') if errors.any? { |e| limit_event?(e) }
    raise Rejected.new(:model, errors.first && error_text(errors.first)) if errors.any? { |e| rejected_event?(e) }
    raise Failed.new(:crash, crash_detail(result, errors)) if errors.any? || !result.exit_code.zero?

    completed = events.reverse.find { |e| e['type'] == 'turn.completed' }
    raise Failed.new(:crash, 'no turn.completed event') unless completed

    Answer.new(critic: read_answer(out_path, validate), usage: completed['usage'])
  end

  def error_text(event)
    body = error_body(event)
    (body&.dig('error', 'message') || event['message'] || event.dig('error', 'message')).to_s[0, 200]
  end

  def crash_detail(result, errors)
    errors.any? ? error_text(errors.first) : "exit #{result.exit_code}"
  end

  def read_answer(path, validate)
    raise Failed.new(:schema, 'no answer file written') unless File.file?(path)

    critic = JSON.parse(File.read(path))
    validate.call(critic)
    critic
  rescue JSON::ParserError
    raise Failed.new(:schema, 'answer was not valid JSON')
  rescue StandardError => e
    raise e if e.is_a?(Error)

    raise Failed.new(:schema, e.message)
  end

  # Runs argv in its own process group with a deadline. On expiry the group gets
  # TERM, a grace period, then KILL, and the child is reaped before returning.
  def run_process(argv, env:, stdin:, timeout:, chdir:, grace: KILL_GRACE)
    opts = { pgroup: true, unsetenv_others: true }
    opts[:chdir] = chdir if chdir
    Open3.popen3(env, *argv, **opts) do |i, o, e, wait|
      writer = Thread.new { feed(i, stdin) }
      readers = [ o, e ].map { |io| Thread.new { io.read } }
      timed_out = wait.join(timeout).nil?
      terminate(wait, grace) if timed_out
      writer.join(1) || writer.kill
      out, err = readers.map { |t| t.join(2) ? t.value : '' }
      Result.new(stdout: out.to_s, stderr: err.to_s, exit_code: timed_out ? nil : wait.value.exitstatus || 1, timed_out: timed_out)
    end
  end

  def feed(io, data)
    io.write(data)
  rescue Errno::EPIPE, IOError
    nil
  ensure
    io.close unless io.closed?
  end

  def terminate(wait, grace)
    signal_group('TERM', wait.pid)
    wait.join(grace)
    # Always sweep the group: a grandchild that ignored TERM outlives its leader.
    signal_group('KILL', wait.pid)
    wait.value
  end

  def signal_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
end
