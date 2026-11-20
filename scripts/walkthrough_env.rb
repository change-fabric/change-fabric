# frozen_string_literal: true

require 'shellwords'
require_relative 'cf_provider_error'
require_relative 'cf_secrets'

# Key lookup for the paid skills. A key comes only from this project's
# enrollment in the per-project store (CfSecrets), is fetched only when its
# provider is actually called, and never appears in an error message, a log
# line, or a file. Process env vars and env files are not key sources.
module WalkthroughEnv
  class MissingKeyError < StandardError; end

  # No usable key for this project (missing, or its recorded expiry passed;
  # to_h[:reason] says which). A MissingKeyError so existing rescues
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
  DEFER_EXIT = 5

  # The user deferred this provider for this project (cf_keys.rb defer) and
  # the deferral has not lapsed. A SystemExit with status 5, so every caller's
  # StandardError rescues let it through and the process exits 5 unchanged:
  # a deferred skip, not an error.
  class Deferred < SystemExit
    def initialize(note) = super(DEFER_EXIT, note)
  end

  module_function

  def elevenlabs_key!(cwd: Dir.pwd) = key!('elevenlabs', cwd: cwd)

  def openai_key!(cwd: Dir.pwd) = key!('openai', cwd: cwd)

  def gemini_key!(cwd: Dir.pwd) = key!('gemini', cwd: cwd)

  # In order, before any network call: (1) an active deferral prints one note
  # and raises Deferred (exit 5); (2) resolve the key, missing raises
  # NeedsEnrollment (exit 4, reason missing); (3) CfSecrets checks the
  # resolved key's expiry: expired raises NeedsEnrollment (reason expired) with
  # no warning line, within 24h warns once per process, else nothing.
  def key!(provider, cwd: Dir.pwd, err: $stderr, now: Time.now)
    defer_check!(provider, cwd, err, now)
    CfSecrets.resolve(provider, cwd: cwd, err: err, now: now)
  rescue CfSecrets::Unenrolled, CfSecrets::Expired => e
    raise NeedsEnrollment, e
  end

  def defer_check!(provider, cwd, err, now)
    slug = CfProjectIdentity.for(cwd).slug
    return unless CfSecretStore.deferral_active?(slug, provider, now: now)

    note = "[cf] #{provider} deferred until #{CfSecretStore.deferred_until(slug, provider).iso8601}; skipping paid step"
    err.puts(note)
    raise Deferred, note
  end

  # Prints the cf_enroll JSON line (no values), the snippet for the user to run
  # in their own terminal, and, when an ancestor key exists, the inherit
  # question. Returns the exit code, for CLIs whose run returns a status.
  def enroll(err, out: $stdout)
    details = err.to_h
    return scratchpad(err, out) if scratchpad?(details)

    out.puts(JSON.generate(cf_enroll: details))
    return expired(details, out) if details[:reason] == 'expired'

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

  # A scratchpad is never enrolled, so no cf_enroll line and no snippet: the
  # loud error names the --project fix instead.
  def scratchpad?(details)
    require_relative 'key_project'
    details[:reason] == 'scratchpad' || KeyProject.scratch_root?(details[:project_root])
  end

  def scratchpad(err, out)
    details = err.to_h
    out.puts(details[:reason] == 'scratchpad' ? err.message : KeyProject.unresolved_message(cwd: details[:project_root], reason: 'no project was named'))
    ENROLL_EXIT
  end

  def expired(details, out)
    label = details[:label] ? " \"#{details[:label]}\"" : ''
    out.puts("The #{details[:provider]} key#{label} enrolled at #{details[:owner_root]} expired at " \
             "#{details[:expires_at]}; no paid request was made. Paste this for the user to renew it in their own " \
             "terminal: #{details[:snippet]}. If the recorded date is wrong, correct it with: #{details[:correct]}")
    ENROLL_EXIT
  end

  # Same output, then exits 4.
  def enroll_exit!(err, out: $stdout) = exit(enroll(err, out: out))

  # A named provider failure (CfProviderError::Failure) as the exit contract:
  # auth_revoked is an enrollment problem, so a cf_enroll line with reason
  # revoked and exit 4; every other class a cf_key_error line and exit 1.
  # Both lines carry the next step and never a key value.
  def key_error(err, out: $stdout, cwd: Dir.pwd)
    return revoked(err, out, cwd) if err.is_a?(CfProviderError::AuthRevoked)

    out.puts(JSON.generate(cf_key_error: err.to_h))
    out.puts("error: #{err.message}. Next: #{err.next_step}")
    1
  end

  def key_error_exit!(err, out: $stdout, cwd: Dir.pwd) = exit(key_error(err, out: out, cwd: cwd))

  def revoked(err, out, cwd = Dir.pwd)
    project = CfProjectIdentity.for(cwd)
    owner = CfSecrets.owning_level(project, err.provider) || { root: project.root }
    snippet = CfKeys.snippet(err.provider, owner[:root])
    out.puts(JSON.generate(cf_enroll: { provider: err.provider, project_root: project.root, project_id: project.id,
                                        reason: 'revoked', owner_root: owner[:root], status: err.status,
                                        snippet: snippet }))
    out.puts("The #{err.provider} key enrolled at #{owner[:root]} was rejected by the provider (HTTP #{err.status}, " \
             "revoked or invalid); no retry was made. Paste this for the user to enroll a new key in their own " \
             "terminal: #{snippet}")
    ENROLL_EXIT
  end
end
