#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'hook_event'
require_relative 'guarded_command'
require_relative 'change_policy'

# PreToolUse hook: denies force-push and history rewrite of trunk or a
# protected branch, and deleting one, in every merge mode and under every
# autopilot. It never reads an environment variable or an autopilot: there is
# no escape hatch, and a real trunk repair is done by a human from a real
# terminal. Unlike the other guards it fails closed: a push it cannot parse
# that carries a force flag is denied.
#
# Denied:
#   - git push with -f, --force, --force-with-lease, --force-if-includes,
#     --mirror or a +refspec, when a destination (or, for a bare push, the
#     current branch) is protected;
#   - git push --delete <protected> and git push <remote> :<protected>;
#   - gh api DELETE on git/refs/heads/<protected> or branches/<protected>/protection,
#     and PATCH on git/refs/heads/<protected> with force=true;
#   - git filter-branch or filter-repo in a command that also pushes to a
#     protected branch.
# Force-push to a feature branch stays allowed: PR rebases need it.
class ForcePushGuard
  EVENT = 'PreToolUse'
  TRUNK = GuardedCommand::TRUNK

  def initialize(event, branch: nil, protected_branches: nil)
    @event = event
    @branch = branch
    @protected_branches = protected_branches
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'

    reason = violation
    io.puts(JSON.generate(deny(reason))) if reason
  rescue StandardError
    io.puts(JSON.generate(deny('the command could not be checked and names a forced push'))) if forceish?
  end

  def violation
    return nil unless command.match?(/\b(?:git|gh)\b/)
    return 'a forced push that cannot be parsed' if unparseable? && forceish?

    push_violation || gh_api_violation || rewrite_violation
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  def unparseable?
    GuardedCommand.lex(command)
    false
  rescue ArgumentError
    true
  end

  def forceish? = command.match?(/\bpush\b/) && command.match?(/(?:\s-[a-zA-Z]*f|--force|--mirror|\s\+\S)/)

  def push_violation
    GuardedCommand.push_args(command).each_with_index do |args, index|
      force = args.any? { |arg| GuardedCommand.force_arg?(arg) }
      return 'git push --mirror rewrites every branch, trunk included' if args.include?('--mirror')
      return 'a forced push of every branch (--all or --branches)' if force && (args & %w[--all --branches]).any?

      deleting = args.include?('--delete') || args.include?('-d')
      dests = destinations(args, index)
      if deleting
        hit = positionals(args).drop(1).find { |name| protected?(strip_ref(name)) }
        return "deleting the protected branch '#{strip_ref(hit)}'" if hit
      end
      colon = dests.find { |dest, refspec| refspec.start_with?(':') && (protected?(dest) || dest.include?('*')) }
      return "deleting the protected branch '#{colon.first}'" if colon
      next unless force

      wild = dests.find { |dest, _| dest.include?('*') }
      return "a forced push of the wildcard refspec '#{wild.last}'" if wild

      targets = dests.empty? ? [ current_branch(index) ] : dests.map(&:first)
      hit = targets.find { |dest| dest.nil? || protected?(dest) }
      return "a force-push to '#{hit || 'an unknown current branch'}'" if targets.include?(hit)
    end
    nil
  end

  def positionals(args)
    skip = false
    args.each_with_object([]) do |arg, out|
      if skip
        skip = false
      elsif %w[-o --push-option --repo --receive-pack --exec].include?(arg)
        skip = true
      elsif !arg.start_with?('-')
        out << arg
      end
    end
  end

  # [[destination branch, refspec]] for each refspec (the first positional is the remote).
  def destinations(args, index = 0)
    positionals(args).drop(1).map do |spec|
      plain = spec.delete_prefix('+')
      dest = plain.include?(':') ? plain.split(':', 2).last : plain
      dest = current_branch(index) if dest == 'HEAD'
      [ strip_ref(dest), plain ]
    end
  end

  def strip_ref(name) = name.to_s.delete_prefix('refs/heads/')

  def gh_api_violation
    GuardedCommand.segments(GuardedCommand.tokens(command)).each do |seg|
      next unless seg.each_cons(2).include?(%w[gh api])

      verb = api_method(seg)
      seg.each do |token|
        ref = token[%r{git/refs/heads/([^?\s]+)}, 1]
        return "deleting the protected branch '#{ref}' through gh api" if ref && verb == 'DELETE' && protected?(ref)
        return "a forced ref update of '#{ref}' through gh api" if ref && verb == 'PATCH' && protected?(ref) && seg.any? { |t| t.match?(/\Aforce=true\z/i) }

        protection = token[%r{branches/([^/\s]+)/protection}, 1]
        return "removing the protection of '#{protection}' through gh api" if protection && verb == 'DELETE' && protected?(protection)
      end
    end
    nil
  end

  def api_method(seg)
    seg.each_with_index do |token, index|
      return seg[index + 1].to_s.upcase if %w[-X --method].include?(token)
      return token.split(/\A(?:-X|--method=)/, 2).last.upcase if token.match?(/\A(?:-X\w|--method=)/)
    end
    'GET'
  end

  def rewrite_violation
    return nil unless command.match?(/\bfilter-(?:branch|repo)\b/)

    pushed = GuardedCommand.push_args(command).each_with_index.flat_map { |args, index| destinations(args, index).map(&:first).then { |d| d.empty? ? [ current_branch(index) ] : d } }
    hit = pushed.find { |dest| dest.nil? || protected?(dest) }
    "a history rewrite pushed to '#{hit || 'an unknown branch'}'" if pushed.include?(hit)
  end

  def protected?(name) = TRUNK.include?(name.to_s) || protected_branches.include?(name.to_s)

  def protected_branches
    @protected_branches ||= begin
      root = git('rev-parse', '--show-toplevel')
      (root && ChangePolicy.for_repo(root)&.protected_branches) || []
    rescue StandardError
      []
    end
  end

  # The branch the index-th push runs on: its own -C repository when it names
  # one, else the session's.
  def current_branch(index = 0)
    return @branch if @branch && push_dirs[index].nil?

    @branches ||= {}
    return @branches[index] if @branches.key?(index)

    dir = push_dirs[index]
    name = git(*(dir ? [ '-C', dir ] : []), 'rev-parse', '--abbrev-ref', 'HEAD')
    @branches[index] = name && name != 'HEAD' ? name : nil
  end

  def push_dirs = @push_dirs ||= GuardedCommand.push_chdirs(command)

  def git(*args)
    out, status = Open3.capture2e('git', *args)
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason:
          "[cf] #{reason} is denied in every merge mode and under every autopilot. Force-push to a feature branch " \
          'is fine; a trunk or protected-branch repair is done by a human from a real terminal. No escape hatch.'
      }
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('force_push_guard', event) { ForcePushGuard.new(event).emit }
end
