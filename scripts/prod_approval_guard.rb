#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'hook_event'

# PreToolUse (Bash): denies the agent every route to approving, or tampering
# with the state of, a bounded prod op. Production credentials never reach the
# agent, so the remaining risk is the agent granting itself the approval:
#
#   change_prod_approve.rb                      the human-only approval tool
#   gh api .../actions/runs/N/pending_deployments   approving a deployment review
#   gh api .../environments/... (a write)        protection rules, reviewers, branch policy
#   git push or gh api writes to refs/cf-prod/{approvals,claims,lock,journal,autopilots,
#                                              autopilot-ends,audit}
#
# The console verbs (enroll, totp-enroll, unlock, revoke, verify --write) are
# already denied by secrets_read_guard.rb. There is no escape hatch for the
# agent: a human runs the command in a real terminal. The limit, stated in
# PRINCIPLES.md, is that the agent's admin token can still call these APIs from
# anywhere a hook does not see. Friction, not a sandbox. Fails silent on error.
class ProdApprovalGuard
  EVENT = 'PreToolUse'
  APPROVE_CLI = 'change_prod_approve.rb'
  MARKERS = [ APPROVE_CLI, 'pending_deployments', '/environments', 'cf-prod' ].freeze
  PENDING = %r{repos/[^/\s]+/[^/\s]+/actions/runs/[^/\s]+/pending_deployments}
  ENVIRONMENTS = %r{repos/[^/\s]+/[^/\s]+/environments(?:/|\z|\?)}
  GIT_WRITE_VERBS = %w[push update-ref fast-import replace receive-pack send-pack].freeze
  GIT_ARG_OPTIONS = %w[-C -c --git-dir --work-tree --namespace --super-prefix --config-env --exec-path].freeze
  WORKFLOW = '.github/workflows/cf-prod.yml'
  WRITE_METHODS = %w[PUT POST PATCH DELETE].freeze
  FIELD_FLAGS = %w[-f -F --field --raw-field --input].freeze

  def initialize(event) = @event = event

  def emit(io = $stdout)
    reason = denial
    io.puts(JSON.generate(deny(reason))) if reason
  rescue StandardError
    nil
  end

  def denial
    return unless @event['tool_name'] == 'Bash'

    input = @event['tool_input']
    command = without_data(input.is_a?(Hash) ? input['command'].to_s : '')
    list = words(command)
    stream = stream_denial(list)
    return stream if stream

    queued = queue_denial(list, command)
    return queued if queued
    return unless MARKERS.any? { |marker| command.include?(marker) }

    inspect_words(list, command)
  rescue ArgumentError
    'an unparseable shell command naming a prod approval path' if unparseable_denied?(command)
  end

  private

  UNPARSEABLE_MARKERS = [ *MARKERS, 'approval_console.rb', 'cf_run_approved.rb', 'manual/queue' ].freeze

  # Fails closed on any approval path or queue mention, and on every
  # unparseable command run from inside the queue directory.
  def unparseable_denied?(command)
    UNPARSEABLE_MARKERS.any? { |marker| command.include?(marker) } || @event['cwd'].to_s.match?(QUEUE_DIR)
  end

  # Quoted text, here-strings and a trailing comment are consumed before a
  # heredoc operator can match, so `echo '<<EOF'`, `cat <<< x` and `# <<EOF`
  # queue no terminator.
  SHELL_TOKEN = /'[^']*'|"(?:\\.|[^"\\])*"|(?<![^\s;&|(])#.*|<<<|<<(-?)[ \t]*(['"]?)([\w.-]+)\2/
  HERESTRING = /<<<[ \t]*('[^']*'|"(?:\\.|[^"\\])*"|[^\s;&|<>()`]+)/
  # A shell anywhere in command position on the line, by name or path
  # (`bash <<X`, `/bin/bash<<X`, `cat <<X | sh`).
  SHELL_FEED = %r{(?:\A|[\s;&|(])(?:[^\s;&|()<>]*/)?(?:bash|sh|zsh|dash|ksh|source|eval)(?=[\s<>;&|)]|\z)}
  EXPANSION = /\$\(|`/

  # The command with heredoc bodies and here-string words removed: they are
  # stdin data, not argv. Kept as commands: a line that feeds a shell, an
  # unquoted heredoc body line or here-string holding a command substitution.
  def without_data(command)
    pending = []
    command.each_line(chomp: true).filter_map { |line| pending.empty? ? command_line(line, pending) : body_line(line, pending) }.join("\n")
  end

  def command_line(line, pending)
    shell = line.match?(SHELL_FEED)
    line.scan(SHELL_TOKEN) { |dash, quote, word| pending << { word:, tabs: dash == '-', shell:, expand: quote.empty? } if word }
    return line if shell

    line.gsub(HERESTRING) { |match| ::Regexp.last_match(1).match?(EXPANSION) && !::Regexp.last_match(1).start_with?("'") ? match : '<<< _' }
  end

  def body_line(line, pending)
    heredoc = pending.first
    return pending.shift && nil if (heredoc[:tabs] ? line.sub(/\A\t+/, '') : line) == heredoc[:word]

    # A substitution can span lines, so from the first one on, an unquoted
    # body is kept whole.
    heredoc[:expanding] ||= heredoc[:expand] && line.match?(EXPANSION)
    line if heredoc[:shell] || heredoc[:expanding]
  end

  # Shell words, plus the words inside any quoted argument (`bash -c '...'`).
  def words(command)
    Shellwords.split(command).flat_map do |word|
      word.match?(/\s/) ? [ word, *words(word) ] : [ word ]
    rescue ArgumentError
      [ word ]
    end
  end

  def inspect_words(list, command)
    return "a shell command running #{APPROVE_CLI}" if list.any? { |word| File.basename(word) == APPROVE_CLI }

    api = api_calls(list)
    api.each do |args|
      return 'a gh api call to pending_deployments' if args.any? { |arg| arg.match?(PENDING) }
      return 'a gh api write to a repository environment' if env_write?(args)
    end
    return 'a gh api write in a command naming cf-prod' if command.include?('cf-prod') && api.any? { |args| write?(args) }
    return 'a git write in a command naming cf-prod' if command.include?('cf-prod') && git_verbs(list).intersect?(GIT_WRITE_VERBS)

    nil
  end

  QUEUE = %r{cf/manual/queue/}
  QUEUE_DIR = %r{cf/manual/queue/?\z}
  SCRIPT_FILE = /\.(?:sh|rb)\z/
  QUEUED_NAME = /\A(?:\.\/)?\d{4}-[\w.-]+\.(?:sh|rb)\z/
  RUNNER_CLI = 'cf_run_approved.rb'
  INTERPRETERS = %w[bash sh zsh dash ksh source . ruby python python3 node perl].freeze
  WRAPPERS = %w[env time nohup sudo command exec xargs nice].freeze
  OPTION_VALUES = %w[-o +o -O +O -I -r].freeze
  SEGMENT_BREAKS = /&&|\|\||[;&|\n`()]|\$\(/
  CHAINING = /[;&|<>`\n]|\$\(/

  # A script queued under ~/.claude/cf/manual/queue/ runs only through
  # `ruby cf_run_approved.rb <script>`, which needs Patrick's phone approval of
  # that exact script text. Running one any other way (interpreter with or
  # without options, ./path, source) is denied. Reading or listing the queue
  # stays open. A loud guardrail, not a sandbox: the agent's own shell is the limit.
  def queue_denial(list, command)
    @in_queue = @event['cwd'].to_s.match?(QUEUE_DIR)
    return nil unless @in_queue || command.include?('manual/queue')
    return nil if runner_only?(list, command)

    return piped_denial if piped_or_redirected?(command)

    segment = command.gsub(/\d*[<>]&\d*-?|&>>?/, ' ').split(SEGMENT_BREAKS).map { |part| part.tr(%q('"), ' ').split }.find { |words| runs_queued?(words) }
    segment && 'a shell command running a queued script directly: queued scripts run only through ' \
               "`ruby #{RUNNER_CLI} <script>` after a phone run-script approval"
  end

  PIPED_DENIAL = 'a queued script fed to a shell through a pipe or redirection: queued scripts run only through ' \
                 '`ruby cf_run_approved.rb <script>` after a phone run-script approval'

  # `bash < <queued>` and `cat <queued> | bash`: the script reaches an
  # interpreter on stdin, so no argument names it.
  def piped_or_redirected?(command)
    shells = INTERPRETERS.map { |name| Regexp.escape(name) }.join('|')
    wrappers = WRAPPERS.join('|')
    command.match?(%r{(?:\A|[\s;&|(])(?:#{shells})\b[^;&|\n]*<[^<]*cf/manual/queue/}) ||
      (command.match?(/\|\s*(?:(?:#{wrappers})\s+)*(?:#{shells})\b/) && command.match?(QUEUE))
  end

  def piped_denial = PIPED_DENIAL

  def runner_only?(list, command)
    !command.match?(CHAINING) && list.first.to_s.end_with?('ruby') && File.basename(list[1].to_s) == RUNNER_CLI
  end

  # Whether one simple command runs a queued script: its command word (after
  # variable assignments and wrappers such as env or time) is the script, or it
  # is an interpreter whose script operand (the first argument that is not an
  # option or an option's value) is one. A queued path that is only some other
  # argument, such as `approval_console.rb request --script <queued>`, is a read.
  def runs_queued?(words)
    words = words.drop_while { |word| word.match?(/\A\w+=/) || WRAPPERS.include?(File.basename(word)) || word.start_with?('-') }
    return false if words.empty?
    return true if queued_word?(words.first)

    # An interpreter in command position, also inside `sh -c '...'`.
    words.each_index.any? do |i|
      command_position = i.zero? || words[i - 1] == '-c' || WRAPPERS.include?(File.basename(words[i - 1]))
      command_position && INTERPRETERS.include?(File.basename(words[i])) && queued_word?(script_operand(words.drop(i + 1)).to_s)
    end
  end

  def script_operand(args)
    args = args.reject { |arg| arg.match?(/\A\d*[<>&]/) }
    args.shift(OPTION_VALUES.include?(args.first) ? 2 : 1) while args.first&.start_with?('-', '+')
    args.first
  end

  # A word naming a queued script: a path into the queue, a queue-style name, or
  # (when the shell is already in the queue dir) any script file there.
  def queued_word?(word) = word.match?(QUEUE) || word.match?(QUEUED_NAME) || (@in_queue && word.match?(SCRIPT_FILE))

  # The argument run after each `gh api`.
  def api_calls(list)
    list.each_index.filter_map { |i| list[(i + 2)..] if list[i] == 'gh' && list[i + 1] == 'api' }
  end

  def env_write?(args) = args.any? { |arg| arg.match?(ENVIRONMENTS) } && write?(args)

  # An explicit non-GET method, or any field flag (gh defaults those to POST).
  def write?(args)
    method = method_of(args)
    return WRITE_METHODS.include?(method) if method
    return false if method_given?(args)

    args.any? { |arg| FIELD_FLAGS.include?(arg) || arg.start_with?('--field=', '--raw-field=', '--input=') || arg.match?(/\A-[fF]./) }
  end

  def method_given?(args) = !method_of(args).nil?

  def method_of(args)
    args.each_with_index do |arg, i|
      return args[i + 1].to_s.upcase if %w[-X --method].include?(arg)
      return arg.sub(/\A--method=/, '').upcase if arg.start_with?('--method=')
      return arg.sub(/\A-X/, '').upcase if arg.match?(/\A-X.+/)
    end
    nil
  end

  # The verb of every `git` invocation, skipping git's global options (and
  # their arguments), so `git -C . push` and `git -c k=v push` read as push.
  # A bare `git-receive-pack` style plumbing name counts as its own verb. An
  # alias defined on the command line (`-c alias.x=push`) makes every verb
  # suspect, reported as a write.
  def git_verbs(list)
    list.each_index.flat_map do |i|
      name = File.basename(list[i])
      next [ name.delete_prefix('git-') ] if name.start_with?('git-') && GIT_WRITE_VERBS.include?(name.delete_prefix('git-'))
      next [] unless name == 'git'

      git_verb_after(list, i + 1)
    end
  end

  def git_verb_after(list, index)
    while index < list.size
      word = list[index]
      return [ 'push' ] if word == '-c' && list[index + 1].to_s.start_with?('alias.')
      return [ word ] unless word.start_with?('-')

      index += GIT_ARG_OPTIONS.include?(word) ? 2 : 1
    end
    []
  end

  # `git update-ref --stdin` and `git fast-import` take their ref names from a
  # stream the command text does not show, so in a repo with the cf-prod
  # workflow they are denied outright.
  def stream_denial(list)
    verbs = git_verbs(list)
    stream = verbs.include?('fast-import') || (verbs.include?('update-ref') && list.include?('--stdin'))
    return unless stream && cf_prod_repo?

    'a git stream write (update-ref --stdin or fast-import) in a repo with cf-prod configured'
  end

  def cf_prod_repo?
    dir = File.expand_path(@event['cwd'].to_s.empty? ? Dir.pwd : @event['cwd'])
    loop do
      return true if File.exist?(File.join(dir, WORKFLOW))
      return false if dir == File.dirname(dir)

      dir = File.dirname(dir)
    end
  end

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: "[cf:prod] #{reason}. Production approvals are human-only: run it yourself in a real terminal. " \
                                  'The agent never approves its own prod op.'
      }
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('prod_approval_guard', event) { ProdApprovalGuard.new(event).emit }
end
