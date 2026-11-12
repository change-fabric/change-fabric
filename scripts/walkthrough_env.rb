# frozen_string_literal: true

require_relative 'cf_secrets'

# Key lookup for the paid skills. A key comes only from this project's
# enrollment in the per-project store (CfSecrets), is fetched only when its
# provider is actually called, and never appears in an error message, a log
# line, or a file. Process env vars and env files are not key sources.
module WalkthroughEnv
  class MissingKeyError < StandardError; end

  # No usable key for this project. A MissingKeyError so existing rescues
  # still catch it; callers that can stop for the user rescue it first and
  # call enroll / enroll_exit!.
  class NeedsEnrollment < MissingKeyError
    def initialize(cause_error)
      @details = cause_error.to_h
      super(cause_error.message)
    end

    def to_h = @details
  end

  ENROLL_EXIT = 4

  module_function

  def elevenlabs_key! = key!('elevenlabs')

  def openai_key! = key!('openai')

  def gemini_key! = key!('gemini')

  def key!(provider)
    CfSecrets.resolve(provider)
  rescue CfSecrets::Unenrolled => e
    raise NeedsEnrollment, e
  end

  # Prints the cf_enroll JSON line (no values), the snippet for the user to run
  # in their own terminal, and, when an ancestor key exists, the inherit
  # question. Returns the exit code, for CLIs whose run returns a status.
  def enroll(err, out: $stdout)
    details = err.to_h
    out.puts(JSON.generate(cf_enroll: details))
    out.puts("No #{details[:provider]} key is enrolled for #{details[:project_root]}. " \
             "Paste this for the user to run in their own terminal: #{details[:snippet]}")
    if details[:inheritable_from]
      out.puts("A #{details[:provider]} key is enrolled at #{details[:inheritable_from]}. Ask the user with " \
               "AskUserQuestion whether this project may use it; on yes run: " \
               "ruby ~/.claude/cf/bin/cf_keys.rb confirm-inherit #{details[:provider]} " \
               "--dir #{Shellwords.escape(details[:project_root].to_s)}")
    end
    ENROLL_EXIT
  end

  # Same output, then exits 4.
  def enroll_exit!(err, out: $stdout) = exit(enroll(err, out: out))
end
