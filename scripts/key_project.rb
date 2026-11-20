# frozen_string_literal: true

require 'optparse'
require 'tmpdir'
require_relative 'walkthrough_env'

# Which directory a paid script looks its API key up against. A script run from
# a Claude Code session scratchpad has no enrollment of its own (the scratchpad
# is a throwaway dir), so it names the project explicitly with --project DIR.
# This returns a directory only; it never reads or returns a key. The script
# hands the directory to WalkthroughEnv as cwd:, and CfSecrets does the lookup
# with its normal owning-level rules.
#
#   --project DIR given        its realpath; a missing dir or a scratchpad is
#                              refused (Invalid, exit 2)
#   cwd outside any scratchpad cwd unchanged, nothing printed
#   cwd under a scratchpad     Unresolved (exit 4, a loud error naming the fix)
#
# The scratchpad path is never decoded and no env var overrides the project.
module KeyProject
  # Claude Code's session scratchpad: <tmp>/claude-<uid>/<project>/<session>/scratchpad.
  SCRATCH_SHAPE = %r{\A/claude-(\d+)/[^/]+/[^/]+/scratchpad(?:/|\z)}
  FIXED_TMP_ROOTS = [ '/private/tmp', '/tmp' ].freeze
  SESSION_ENV = 'CLAUDE_CODE_SESSION_ID'

  # An unusable --project value. A ParseError, so every CLI that rescues
  # option errors already exits 2 with the message.
  class Invalid < OptionParser::ParseError
    def initialize(message)
      @text = message
      super()
    end

    def message = @text
    alias to_s message
  end

  # A scratchpad run with no project to resolve it against. A NeedsEnrollment
  # so existing exit 4 rescues stop it; WalkthroughEnv.enroll prints the fix
  # instead of a cf_enroll line, because the scratchpad is never enrolled.
  class Unresolved < WalkthroughEnv::NeedsEnrollment
    Cause = Struct.new(:message, :to_h)

    attr_reader :cwd

    def initialize(cwd:, session: nil, reason: nil)
      @cwd = cwd
      text = KeyProject.unresolved_message(cwd: cwd, session: session, reason: reason)
      super(Cause.new(text, { reason: 'scratchpad', project_root: cwd }))
    end
  end

  module_function

  # argv_project is the --project value or nil.
  def resolve(argv_project: nil, cwd: Dir.pwd, env: ENV)
    return explicit(argv_project) if argv_project

    real = real_path(cwd)
    return cwd unless real && scratch_root?(real)

    raise Unresolved.new(cwd: real, session: env[SESSION_ENV], reason: 'no session record is read yet')
  end

  def explicit(dir)
    expanded = File.expand_path(dir.to_s)
    raise Invalid, "cf: --project #{dir} is not a directory" unless File.directory?(expanded)

    real = File.realpath(expanded)
    if scratch_root?(real)
      raise Invalid, "cf: --project #{real} is a Claude Code session scratchpad, not a project. " \
                     'Pass the repo root instead.'
    end
    real
  end

  def scratch_root?(real, uid: Process.uid)
    return false if real.nil?

    (FIXED_TMP_ROOTS + [ tmp_realpath ]).compact.uniq.any? do |root|
      next false unless real.start_with?("#{root}/")

      m = SCRATCH_SHAPE.match(real.delete_prefix(root))
      !m.nil? && m[1].to_i == uid
    end
  end

  def tmp_realpath
    File.realpath(Dir.tmpdir)
  rescue SystemCallError
    nil
  end

  def real_path(dir)
    File.realpath(File.expand_path(dir.to_s))
  rescue SystemCallError
    nil
  end

  def unresolved_message(cwd:, session: nil, reason: nil)
    who = session.to_s.empty? ? 'unknown session' : session
    "cf: paid key lookup refused: #{cwd} is a Claude Code session scratchpad, and the\n" \
      "session record for #{who} has no project (#{reason || 'none recorded'}).\n" \
      'Fix: re-run with --project <repo root>'
  end

  # Adds --project DIR to an OptionParser, storing it in holder[:project].
  def add_option(opts, holder)
    opts.on('--project DIR', 'directory whose enrolled key paid calls use (default: the cwd)') { |v| holder[:project] = v }
  end

  # `--project DIR` or `--project=DIR` out of a bare argv, for scripts without
  # an OptionParser. Mutates args; returns the value or nil.
  def take_option(args)
    i = args.index { |a| a == '--project' || a.start_with?('--project=') }
    return nil unless i

    arg = args.delete_at(i)
    return arg.split('=', 2).last if arg.include?('=')

    args.delete_at(i) || raise(Invalid, 'cf: --project needs a directory')
  end
end
