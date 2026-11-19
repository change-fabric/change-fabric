# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'change_prod_envelope'

# The runner's state: JSON payloads held as single parentless commits under
# refs/cf-prod/<kind>/<request_id>. Creation is conditional: the local
# update-ref names a zero old value and the push is never forced, so a ref that
# already exists (here or on the remote) refuses. That is what makes a claim a
# real single-use lock. The admin token can still write these refs outside
# hooks (documented in PRINCIPLES.md).
class ChangeProdStore
  class Error < StandardError; end
  class Exists < Error; end
  class Missing < Error; end

  KINDS = %w[requests approvals claims issued].freeze
  # `issued` holds one marker per environment: refs/cf-prod/issued/<id>/<env>.
  # It is not nested under claims/<id> because git cannot hold a ref and a
  # directory of refs at the same path.
  ENV_NAME = /\A[a-z][a-z0-9_-]{0,62}\z/
  PAYLOAD = 'payload.json'
  ZERO = '0' * 40

  def initialize(root, remote: 'origin')
    @root = root
    @remote = remote
  end

  def ref(kind, request_id, env: nil)
    raise Error, "unknown ref kind #{kind.inspect}" unless KINDS.include?(kind)
    raise Error, 'request_id is not a uuid' unless request_id.to_s.match?(ChangeProdEnvelope::UUID)
    raise Error, 'an issued marker needs an environment, and only it takes one' unless (kind == 'issued') == !env.nil?
    raise Error, 'environment is malformed' if env && !env.to_s.match?(ENV_NAME)

    [ "refs/cf-prod/#{kind}/#{request_id}", env ].compact.join('/')
  end

  # Creates the ref or raises Exists. With `push`, the ref must also be created
  # on the remote; a failed push removes the local ref again.
  def create(kind, request_id, payload, push: true, env: nil)
    name = ref(kind, request_id, env: env)
    commit = write_commit(JSON.generate(payload))
    _out, err, status = git('update-ref', name, commit, ZERO)
    raise Exists, "#{name} already exists: #{err.strip}" unless status.success?

    publish(name) if push
    name
  end

  def publish(name)
    _out, err, status = git('push', @remote, "#{name}:#{name}")
    return if status.success?

    git('update-ref', '-d', name)
    raise Exists, "#{name} could not be created on #{@remote}: #{err.lines.last.to_s.strip}"
  end

  def fetch
    _out, err, status = git('fetch', '--quiet', @remote, '+refs/cf-prod/*:refs/cf-prod/*')
    raise Error, "fetching refs/cf-prod failed: #{err.strip}" unless status.success?
  end

  def exists?(kind, request_id, env: nil)
    _out, _err, status = git('rev-parse', '--verify', '--quiet', ref(kind, request_id, env: env))
    status.success?
  end

  def read(kind, request_id, env: nil)
    name = ref(kind, request_id, env: env)
    out, _err, status = git('show', "#{name}:#{PAYLOAD}")
    raise Missing, "#{name} does not exist" unless status.success?

    JSON.parse(out)
  rescue JSON::ParserError
    raise Error, "#{name} does not hold valid JSON"
  end

  private

  def write_commit(json)
    blob = capture('hash-object', '-w', '--stdin', stdin: json)
    tree = capture('mktree', stdin: "100644 blob #{blob}\t#{PAYLOAD}\n")
    capture('-c', 'commit.gpgsign=false', '-c', 'user.name=cf-prod', '-c', 'user.email=cf-prod@users.noreply.github.com', 'commit-tree', tree, '-m', 'cf-prod state')
  end

  def capture(*args, stdin: nil)
    out, err, status = git(*args, stdin: stdin)
    raise Error, "git #{args.first} failed: #{err.strip}" unless status.success?

    out.strip
  end

  def git(*args, stdin: nil)
    Open3.capture3('git', '-C', @root, *args, stdin_data: stdin.to_s)
  end
end
