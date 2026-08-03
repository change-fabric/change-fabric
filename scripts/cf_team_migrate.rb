#!/usr/bin/env ruby
# frozen_string_literal: true

# cf-team-migrate: human-run, once per repo, to carry a contributors team that
# already exists onto the hosted platform.
#
# A team registered by `cf_team_init.rb` is a `contributors_team:` block in a
# repo's CHANGE.md: a `team_id`, an Ed25519 public key, and a roster of
# self-asserted `{id, name}` pairs. That registration is what the presence and
# secret-alert hooks read, and it keeps working exactly as it is. This script
# does not replace it. It creates the platform's own record of the same team
# ALONGSIDE it: an organization, a team carrying the old `team_id` as
# `legacyTeamId` and the old public key as `publicKeyEd25519`, one
# `contributor_alias` per roster entry so historical attribution still resolves,
# a `repo_link` for this repo, and a team API key to publish findings artifacts
# with.
#
# It then PRINTS the replacement frontmatter block. It never writes CHANGE.md:
# the block is additive, the file is under review like any other change, and a
# tool that edited it would be deciding on a human's behalf what their repo says
# about who they are.
#
# Idempotent. Running it twice finds the organization, the team, each alias and
# the repo link that already exist and reuses them rather than erroring or
# duplicating. Only the API key is minted afresh every real run, because a key
# is shown exactly once and there is no way to hand back one already issued;
# `--dry-run` reports everything it WOULD do and writes nothing at all.
#
# Unlike the hooks, this is NOT fail-soft, and deliberately mirrors
# `cf_team_init.rb`'s posture: it is one-time provisioning, so a missing
# credential, an unreachable API, or a refused call raises a real exception and
# exits nonzero. Nothing here is rescued and continued past. A migration that
# half happened and said nothing would be worse than one that stopped.

require 'json'
require 'net/http'
require 'optparse'
require 'uri'
require_relative 'change_frontmatter'
require_relative 'contributors_team'

class CfTeamMigrate
  # Where the hosted service answers unless `--api-url` says otherwise. The same
  # default `ChangeArtifactsConfig::DEFAULT_API_URL` carries, for the same
  # reason: staging is what exists, and a production estate is a different
  # origin rather than a different build of this script.
  DEFAULT_API_URL = 'https://api.staging.changefabric.org'

  # The mapping this script assumes when a repo does not say otherwise: one
  # legacy team becomes one team called `core` inside its organization. It is a
  # default and not a rule, because `changefabric-core` and `acme-web` do not
  # decompose into an organization and a team the same way, and only a human
  # knows which half of their own team id was which.
  DEFAULT_TEAM_SLUG = 'core'

  # Env vars, named rather than valued, exactly as every other credential in
  # this toolkit is. The password is the maintainer's own platform account
  # password: this script authenticates as a person, because creating an
  # organization is a person's act and the API has no way for it to be anything
  # else. That is the point, not a limitation worked around.
  PASSWORD_ENV = 'CF_PLATFORM_PASSWORD'
  BASIC_AUTH_USER_ENV = 'CF_PLATFORM_BASIC_AUTH_USER'
  BASIC_AUTH_PASSWORD_ENV = 'CF_PLATFORM_BASIC_AUTH_PASSWORD'

  OPEN_TIMEOUT = 15
  READ_TIMEOUT = 60

  class Error < StandardError; end

  Options = Struct.new(
    :repo_path, :api_url, :email, :name,
    :org_slug, :org_name, :team_slug, :team_name, :key_name, :dry_run,
    keyword_init: true
  )

  def self.run(argv)
    new(parse_options(argv)).run
  end

  def self.parse_options(argv)
    options = Options.new(repo_path: Dir.pwd, api_url: DEFAULT_API_URL, dry_run: false)

    parser = OptionParser.new do |opts|
      opts.banner = 'usage: cf_team_migrate.rb [--repo PATH] --org SLUG --email ADDRESS [options]'
      opts.on('--repo PATH', 'repo to migrate (default: the current directory)') { |v| options.repo_path = v }
      opts.on('--api-url URL', "platform API origin (default: #{DEFAULT_API_URL})") { |v| options.api_url = v }
      opts.on('--email ADDRESS', 'the maintainer account to act as') { |v| options.email = v }
      opts.on('--name NAME', 'display name, used only if the account is created') { |v| options.name = v }
      opts.on('--org SLUG', 'organization slug to resolve or create') { |v| options.org_slug = v }
      opts.on('--org-name NAME', 'organization display name (default: the slug)') { |v| options.org_name = v }
      opts.on('--team SLUG', "team slug (default: #{DEFAULT_TEAM_SLUG})") { |v| options.team_slug = v }
      opts.on('--team-name NAME', 'team display name (default: the slug)') { |v| options.team_name = v }
      opts.on('--key-name NAME', 'label for the minted API key') { |v| options.key_name = v }
      opts.on('--dry-run', 'report what would happen and write nothing') { options.dry_run = true }
    end
    parser.parse(argv)

    raise Error, "--org is required\n#{parser}" if options.org_slug.to_s.empty?
    raise Error, "--email is required\n#{parser}" if options.email.to_s.empty?

    options.team_slug = DEFAULT_TEAM_SLUG if options.team_slug.to_s.empty?
    options.org_name = options.org_slug if options.org_name.to_s.empty?
    options.team_name = options.team_slug if options.team_name.to_s.empty?
    options.key_name = 'cf:change publisher' if options.key_name.to_s.empty?
    options
  end

  def initialize(options)
    @options = options
    @api_url = options.api_url.to_s.sub(%r{/+\z}, '')
    @cookie = nil
  end

  def run
    legacy = read_legacy_block
    say_plan(legacy)

    authenticate
    organization = resolve_organization
    team = resolve_team(organization, legacy)
    membership = resolve_membership(team)
    aliases = resolve_aliases(team, legacy)
    repo_link = resolve_repo_link(team)
    key = mint_key(team)

    report(legacy, organization, team, membership, aliases, repo_link, key)
  end

  private

  attr_reader :options

  def dry_run? = options.dry_run

  # --- what this repo already says about itself --------------------------------

  # The `contributors_team:` block, read from the repo being migrated. This is
  # the one input that is not a flag, and it is required: a repo with no such
  # block has no legacy registration to carry, and inventing one here would
  # create a team nobody registered.
  def read_legacy_block
    root = contributors_team.repo_root
    raise Error, "#{options.repo_path} is not inside a git repository" unless root

    front = ChangeFrontmatter.parse_file(File.join(root, 'CHANGE.md'))
    block = front['contributors_team']
    raise Error, "#{root}/CHANGE.md carries no contributors_team block; nothing to migrate" unless block.is_a?(Hash)

    legacy_team_id = block['team_id'].to_s
    raise Error, 'the contributors_team block has no team_id' if legacy_team_id.empty?

    {
      root: root,
      legacy_team_id: legacy_team_id,
      public_key: block['public_key_ed25519'].to_s,
      contributors: roster(block['contributors']),
      repo_id: repo_id
    }
  end

  def roster(raw)
    return [] unless raw.is_a?(Array)

    raw.select { |entry| entry.is_a?(Hash) && !entry['id'].to_s.empty? }
       .map { |entry| { 'id' => entry['id'].to_s, 'name' => entry['name'].to_s } }
  end

  # The normalized `host/path` repo id, taken from ContributorsTeam rather than
  # recomputed. There is exactly one definition of what identifies a repo across
  # this toolkit, and a second spelling of it here would be a second answer to
  # the question the `repo_link` unique index exists to settle.
  def repo_id
    value = contributors_team.repo_id
    raise Error, "#{options.repo_path} has no git remote, so it has no repo_id to link" if value.to_s.empty?

    value
  end

  def contributors_team = @contributors_team ||= ContributorsTeam.new(options.repo_path)

  # --- authenticating ----------------------------------------------------------

  # Sign in, or sign up and then be signed in. Both are the ordinary Better Auth
  # endpoints a person's browser uses; this script has no privileged path and no
  # secret of its own, which is exactly why it needs none to be added to the API.
  #
  # A dry run authenticates too, because reading is how it discovers what
  # already exists and an unauthenticated dry run could only report a guess. But
  # it signs in ONLY. Creating an account is a write, and a `--dry-run` that
  # leaves a real row behind is not a dry run; it stops and says the account is
  # missing instead, which is itself the useful answer.
  def authenticate
    password = ENV[PASSWORD_ENV].to_s
    raise Error, "set #{PASSWORD_ENV} to the platform password for #{options.email}" if password.empty?

    response = auth_post('/api/auth/sign-in/email', { 'email' => options.email, 'password' => password })

    unless response.is_a?(Net::HTTPSuccess)
      raise Error, no_account_message if dry_run?

      response = sign_up(password)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "could not authenticate as #{options.email}: #{response.code}#{detail(response)}"
    end

    @cookie = session_cookie(response)
    raise Error, 'the API authenticated the account but set no session cookie' unless @cookie
  end

  def no_account_message
    "no platform account for #{options.email} (or the password in #{PASSWORD_ENV} is wrong). " \
      'A real run would create one; a dry run will not, because that is a write. ' \
      'Re-run without --dry-run, or sign up in the web app first.'
  end

  def sign_up(password)
    auth_post('/api/auth/sign-up/email', {
                'name' => options.name.to_s.empty? ? options.email : options.name,
                'email' => options.email,
                'password' => password
              })
  end

  def session_cookie(response)
    pairs = response.get_fields('set-cookie').to_a
                    .map { |cookie| cookie.split(';', 2).first.to_s.strip }
                    .reject(&:empty?)
    pairs.empty? ? nil : pairs.join('; ')
  end

  # --- the organization --------------------------------------------------------

  # Resolve or create, and then make it the session's active one either way.
  # Every /v1 route reads the caller's organization from the session rather than
  # from a body, so an organization that is not active is an organization this
  # script cannot act in, whether it just created it or found it already there.
  def resolve_organization
    found = list_organizations.find { |org| org['slug'].to_s == options.org_slug }

    if found
      set_active_organization(found['id'].to_s)
      return { 'id' => found['id'].to_s, 'slug' => found['slug'].to_s, 'existing' => true }
    end

    if dry_run?
      return { 'id' => nil, 'slug' => options.org_slug, 'existing' => false }
    end

    created = post_json('/v1/onboarding', {
                          'organizationName' => options.org_name,
                          'organizationSlug' => options.org_slug
                        }, expect: 201)['organization']
    set_active_organization(created['id'].to_s)
    { 'id' => created['id'].to_s, 'slug' => created['slug'].to_s, 'existing' => false }
  end

  def list_organizations
    body = get_json('/api/auth/organization/list')
    body.is_a?(Array) ? body : []
  end

  def set_active_organization(organization_id)
    post_json('/api/auth/organization/set-active', { 'organizationId' => organization_id }, expect: 200)
  end

  # --- the team ----------------------------------------------------------------

  # Matched by legacy team id first and by slug second, and the difference
  # matters. The legacy id is the thing being migrated, so a team already
  # carrying it IS this team no matter what it is called now. A slug match with
  # a different legacy id is a collision rather than a match, and is refused
  # rather than silently adopted.
  def resolve_team(organization, legacy)
    return { 'id' => nil, 'slug' => options.team_slug, 'existing' => false } if organization['id'].nil?

    teams = get_json('/v1/teams')['teams'].to_a
    found = teams.find { |team| team['legacyTeamId'].to_s == legacy[:legacy_team_id] }
    found ||= teams.find { |team| team['slug'].to_s == options.team_slug }

    if found
      assert_team_matches(found, legacy)
      return found.merge('existing' => true)
    end

    return { 'id' => nil, 'slug' => options.team_slug, 'existing' => false } if dry_run?

    body = { 'name' => options.team_name, 'slug' => options.team_slug, 'legacyTeamId' => legacy[:legacy_team_id] }
    body['publicKeyEd25519'] = legacy[:public_key] unless legacy[:public_key].empty?
    post_json('/v1/teams', body, expect: 201)['team'].merge('existing' => false)
  end

  # A team found by slug that already carries somebody else's legacy id is not
  # this team, and adopting it would attach this repo's roster and its API key to
  # a stranger. Refused loudly, because there is no safe guess to make.
  def assert_team_matches(team, legacy)
    existing = team['legacyTeamId'].to_s
    return if existing.empty? || existing == legacy[:legacy_team_id]

    raise Error,
          "team #{team['slug']} in #{options.org_slug} already carries legacy team id " \
          "#{existing}, not #{legacy[:legacy_team_id]}; pick another --team slug"
  end

  # --- team membership ----------------------------------------------------------

  # Put the person running this on the team they just migrated.
  #
  # Owning the organization is not the same as being on one of its teams, and
  # the platform means that literally: the viewer cookies that let a browser
  # open a published artifact are minted against a `team_member` row, not
  # against an organization role. Without this step the maintainer migrates
  # their own team, publishes to it, and is then refused when they try to look
  # at the result. Idempotent, because being on a team twice is not a thing.
  def resolve_membership(team)
    return { 'planned' => true } if team['id'].nil?

    user_id = session_user_id
    members = get_json("/v1/teams/#{team['id']}/members")['members'].to_a
    return { 'userId' => user_id, 'existing' => true } if members.any? { |m| m['userId'].to_s == user_id }
    return { 'userId' => user_id, 'planned' => true } if dry_run?

    post_json("/v1/teams/#{team['id']}/members", { 'userId' => user_id }, expect: 201)
    { 'userId' => user_id, 'existing' => false }
  end

  # Who the session says we are. Asked of the API rather than assumed from
  # `--email`, because the account that answered the sign-in is the only
  # authority on its own id.
  def session_user_id
    session = get_json('/api/auth/get-session')
    id = session.is_a?(Hash) ? session.dig('user', 'id').to_s : ''
    raise Error, 'the API did not say who this session belongs to' if id.empty?

    id
  end

  # --- the roster --------------------------------------------------------------

  # One alias per roster entry. The API's own POST is idempotent (it answers 200
  # with the row that already exists rather than 201), so a real re-run needs no
  # read-then-write dance here and cannot race with one. A dry run reads the
  # existing aliases instead and posts nothing.
  #
  # The maintainer's own address is offered for the entry being migrated so the
  # alias can link to a real account, and only that entry: this script knows
  # which address signed in, and it knows nothing about anybody else's.
  def resolve_aliases(team, legacy)
    return legacy[:contributors].map { |entry| entry.merge('planned' => true) } if team['id'].nil?

    return planned_aliases(team, legacy) if dry_run?

    legacy[:contributors].map do |entry|
      body = { 'legacyContributorId' => entry['id'], 'displayName' => entry['name'] }
      body['email'] = options.email if entry['id'] == self_contributor_id(legacy)
      post_json("/v1/teams/#{team['id']}/aliases", body, expect: [ 200, 201 ])
    end
  end

  def planned_aliases(team, legacy)
    existing = get_json("/v1/teams/#{team['id']}/aliases")['aliases'].to_a
    legacy[:contributors].map do |entry|
      found = existing.find { |row| row['legacyContributorId'].to_s == entry['id'] }
      found ? { 'alias' => found, 'created' => false } : entry.merge('planned' => true)
    end
  end

  # Which roster entry is the person running this, according to the machine's
  # own `cf_team_join.rb` record. nil when this machine has not joined the team,
  # which is a normal state and simply means no alias is offered an address.
  def self_contributor_id(legacy)
    identity = contributors_team.identity
    identity && identity.team_id == legacy[:legacy_team_id] ? identity.contributor_id : nil
  end

  # --- the repo link -----------------------------------------------------------

  def resolve_repo_link(team)
    return { 'repoId' => repo_id, 'planned' => true } if team['id'].nil?

    found = get_json('/v1/repos')['repos'].to_a.find { |repo| repo['repoId'].to_s == repo_id }
    return found.merge('existing' => true) if found
    return { 'repoId' => repo_id, 'planned' => true } if dry_run?

    post_json('/v1/repos', { 'teamId' => team['id'], 'repoId' => repo_id }, expect: 201)['repo']
                                                                                        .merge('existing' => false)
  end

  # --- the key -----------------------------------------------------------------

  # Minted every real run, and that is not an idempotency bug. A key is returned
  # by exactly one response and is not recoverable afterwards even by the API,
  # so a re-run has nothing to hand back; minting another is the only honest
  # answer. Old keys stay listed and revocable on the team's page.
  def mint_key(team)
    return nil if dry_run? || team['id'].nil?

    post_json("/v1/teams/#{team['id']}/keys", { 'name' => options.key_name }, expect: 201)
  end

  # --- saying what happened -----------------------------------------------------

  def say_plan(legacy)
    puts dry_run? ? 'DRY RUN: nothing will be written.' : 'Migrating a registered contributors team to the platform.'
    puts
    puts "  repo             #{legacy[:root]}"
    puts "  repo_id          #{legacy[:repo_id]}"
    puts "  legacy team_id   #{legacy[:legacy_team_id]}"
    puts "  public key       #{legacy[:public_key].empty? ? '(none)' : legacy[:public_key]}"
    puts "  contributors     #{legacy[:contributors].map { |c| c['id'] }.join(', ')}"
    puts "  api              #{@api_url}"
    puts "  organization     #{options.org_slug}"
    puts "  team             #{options.team_slug}"
    puts
  end

  def report(legacy, organization, team, membership, aliases, repo_link, key)
    puts(dry_run? ? 'Would create or reuse:' : 'Done:')
    puts "  organization     #{organization['slug']}#{state(organization)}"
    puts "  team             #{team['slug']}#{state(team)}"
    puts "  team membership  #{options.email}#{state(membership)}"
    aliases.each { |entry| puts "  alias            #{alias_line(entry)}" }
    puts "  repo_link        #{repo_link['repoId']}#{state(repo_link)}"
    puts "  team API key     #{dry_run? ? '(would be minted)' : key['apiKey']['keyPrefix']}"
    puts

    return puts('Re-run without --dry-run to apply.') if dry_run?

    print_change_md_block(legacy, organization, team)
    print_key_instructions(organization, team, key)
  end

  def state(record)
    return ' (would be created)' if dry_run? && !record['existing']

    record['existing'] ? ' (already there, reused)' : ' (created)'
  end

  def alias_line(entry)
    return "#{entry['id']} -> #{entry['name']} (would be created)" if entry['planned']

    linked = entry['alias']['userId'] ? 'linked to an account' : 'no account yet'
    reused = entry['created'] ? 'created' : 'already there, reused'
    "#{entry['alias']['legacyContributorId']} -> #{entry['alias']['displayName']} (#{reused}, #{linked})"
  end

  # Printed, never written. The block is ADDITIVE: every legacy field stays
  # exactly as it is, because those fields are what the presence and
  # secret-alert hooks read and nothing about this migration changes that.
  def print_change_md_block(legacy, organization, team)
    puts "Replace the contributors_team block in #{legacy[:root]}/CHANGE.md with this."
    puts 'It is additive: every field you already had is unchanged.'
    puts '---8<--- CHANGE.md frontmatter ---8<---'
    puts 'contributors_team:'
    puts "  team_id: #{legacy[:legacy_team_id]}"
    puts "  public_key_ed25519: #{legacy[:public_key]}" unless legacy[:public_key].empty?
    puts '  contributors:'
    legacy[:contributors].each { |entry| puts "    - { id: #{entry['id']}, name: #{entry['name']} }" }
    puts "  organization: #{organization['slug']}"
    puts "  team: #{team['slug']}"
    puts '  platform:'
    puts "    api_url: #{@api_url}"
    puts '    api_key_env: CF_TEAM_API_KEY'
    puts '    basic_auth:'
    puts "      username_env: #{BASIC_AUTH_USER_ENV}"
    puts "      password_env: #{BASIC_AUTH_PASSWORD_ENV}"
    puts '---8<--------------------------------8<---'
    puts
  end

  # The one and only time this value is printed, labelled as such, exactly as
  # `cf_team_init.rb` prints a private key. It is not written to a file and not
  # echoed anywhere else.
  def print_key_instructions(organization, team, key)
    account = "#{organization['slug']}/#{team['slug']}"
    puts 'The team API key below is shown ONCE and cannot be read back. Store it now:'
    puts
    puts "  KEY: #{key['key']}"
    puts
    puts 'Put it in the Keychain (and, if the team shares one, a 1Password vault):'
    puts
    puts "  ruby scripts/cf_team_join.rb --platform #{organization['slug']} #{team['slug']} --stdin"
    puts
    puts "(reads the key on stdin, caches it under service 'change-fabric-platform', account '#{account}')"
  end

  # --- HTTP ---------------------------------------------------------------------

  def get_json(path) = send_json(Net::HTTP::Get, path, nil, [ 200 ])

  def post_json(path, body, expect:) = send_json(Net::HTTP::Post, path, body, Array(expect))

  def auth_post(path, body)
    uri = URI.parse("#{@api_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['Origin'] = @api_url
    request.body = JSON.generate(body)
    apply_basic_auth(request)
    perform(uri, request)
  end

  def send_json(verb, path, body, expect)
    uri = URI.parse("#{@api_url}#{path}")
    request = verb.new(uri)
    request['Accept'] = 'application/json'
    # Better Auth refuses a cookie-bearing state-changing call that declares no
    # origin (MISSING_OR_NULL_ORIGIN), which is the CSRF protection a browser
    # client gets for free and a command-line one has to state for itself. The
    # API's own base URL is always among its trusted origins, so naming it needs
    # no configuration and widens nothing: this is a client declaring what it
    # already is, not a check being turned off.
    request['Origin'] = @api_url
    request['Cookie'] = @cookie if @cookie
    if body
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
    end
    apply_basic_auth(request)

    response = perform(uri, request)
    raise Error, "#{path} answered #{response.code}#{detail(response)}" unless expect.include?(response.code.to_i)

    parse_body(path, response)
  end

  # The staging-wide Basic Auth fence in front of the API. A property of the
  # deployment rather than of the team, so it is named by env var here exactly
  # as `contributors_team.platform.basic_auth` names it in a repo's CHANGE.md. A
  # deployment without such a fence simply has neither variable set.
  def apply_basic_auth(request)
    username = ENV[BASIC_AUTH_USER_ENV].to_s
    password = ENV[BASIC_AUTH_PASSWORD_ENV].to_s
    return if username.empty? && password.empty?

    request.basic_auth(username, password)
  end

  def parse_body(path, response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise Error, "#{path} answered #{response.code} with a body that is not JSON"
  end

  def detail(response)
    message = JSON.parse(response.body.to_s)['error'].to_s
    message.empty? ? '' : ": #{message[0, 200]}"
  rescue StandardError
    ''
  end

  def perform(uri, request)
    Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https', open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(request) }
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    CfTeamMigrate.run(ARGV)
  rescue CfTeamMigrate::Error => e
    warn "cf_team_migrate: #{e.message}"
    exit 1
  end
end
