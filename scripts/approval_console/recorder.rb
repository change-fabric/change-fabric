# frozen_string_literal: true

require 'json'
require_relative 'canonical'
require_relative 'local_store'
require_relative 'proof_check'
require_relative '../change_approval_store'
require_relative '../change_policy'
require_relative '../change_override_store'
require_relative '../change_carve_out_store'
require_relative '../change_release_store'

module ApprovalConsole
  # The one writer of every phone approval record. Given a console proof and
  # the context the caller asked for, it checks the receipt at the passkey
  # level against the authoritative pins, refuses one whose signed
  # accepted_at is 24h old or more (or over five minutes in the future), checks
  # the claim-table row for the signed type, and only then writes the store
  # for that type with the authoritative `policy_sha`:
  #
  #   step      ChangeApprovalStore   sha + profile + step
  #   override  ChangeOverrideStore   sha + profile
  #   carve-out ChangeCarveOutStore   repo + PR number + head sha
  #   release   ChangeReleaseStore    repo + tag + sha
  #
  # `authority` is a ChangePolicy::Authority (policy and policy_sha) from the
  # base or default branch, never the working tree.
  class Recorder
    MIN_REASON = ProofCheck::MIN_REASON
    PR_URL = %r{\Ahttps://([^/\s]+)/([^/\s]+)/([^/\s]+)/pull/(\d+)/?\z}

    Result = Struct.new(:type, :summary, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    # The default branch's approval authority for the repo checked out at
    # `root` (explicit fetch, origin owner/repo check). Raises
    # ChangePolicy::Unreadable, so callers fail closed.
    def self.authority_for(root)
      repo = ChangePolicy.origin_repo(root) or raise ChangePolicy::Unreadable, "#{root} has no origin remote"
      ChangePolicy.authoritative(root: root, repo: repo)
    end

    def initialize(authority:, store: LocalStore.new, clock: -> { Time.now }, recorded_by: ENV['USER'] || 'unknown',
                   stores: {})
      @authority = authority
      @store = store
      @clock = clock
      @recorded_by = recorded_by.to_s
      @stores = stores
    end

    # Checks `proof` against `expected` (type, repo, sha, profile and the
    # per-type fields the caller asked for) and writes it. Returns a Result.
    def record(proof, expected:)
      expected = expected.to_h { |key, value| [ key.to_s, value ] }
      problem = refusal(proof, expected)
      return Result.new(type: expected['type'], error: problem) if problem

      Result.new(type: expected['type'], summary: write(proof, expected))
    end

    private

    def refusal(proof, expected)
      return 'no proof to record' unless proof.is_a?(Hash)
      return "#{expected['type'].inspect} is not a recordable approval type" unless respond_to?(writer(expected['type']), true)
      return 'no authoritative approval policy was resolved' unless @authority.respond_to?(:policy_sha) && @authority.policy_sha

      claim_problem(expected) || receipt_problem(proof, expected) || stale(proof)
    end

    def receipt_problem(proof, expected)
      check = ProofCheck.new(level: 'passkey', store: @store, pins: @authority.policy&.approval_pins, now: @clock.call)
      problem = check.receipt_problem(proof, expected.except('machine_id'))
      problem && "the receipt is refused: #{problem}"
    end

    def stale(proof)
      return nil if ProofCheck.fresh?(proof, at: @clock.call)

      'the receipt is 24h old or older, or dated in the future; request a new approval'
    end

    def claim_problem(expected)
      case expected['type']
      when 'override'
        "the override reason is under #{MIN_REASON} characters" if expected['reason'].to_s.strip.length < MIN_REASON
      when 'carve-out' then carve_out_problem(expected)
      when 'release' then 'release needs a tag' if expected['tag'].to_s.strip.empty?
      end
    end

    def carve_out_problem(expected)
      host, owner, name, = PR_URL.match(expected['pr_url'].to_s)&.captures
      return 'the carve-out pr_url is not a pull request URL' unless host
      return nil if expected['repo'].to_s.downcase == "repo:#{host}/#{owner}/#{name}".downcase

      "the carve-out repo #{expected['repo']} is not the PR's #{owner}/#{name}"
    end

    def writer(type) = :"write_#{type.to_s.tr('-', '_')}"

    def write(proof, expected) = send(writer(expected['type']), proof, expected)

    def policy_sha = @authority.policy_sha

    def write_step(proof, expected)
      steps = Array(expected['items']).map { |item| [ item['step'].to_s, item['digest'].to_s ] }
      approvals(expected['sha']).record(steps: steps, by: @recorded_by, proof: proof, policy_sha: policy_sha)
      "#{steps.size} step approval(s) for #{expected['sha'][0, 12]}"
    end

    def write_override(proof, expected)
      overrides(expected['sha'], expected['profile']).record(reason: expected['reason'], recorded_by: @recorded_by,
                                                             proof: proof, policy_sha: policy_sha)
      "override for #{expected['sha'][0, 12]}#{expected['profile'] ? " (profile: #{expected['profile']})" : ''}"
    end

    def write_carve_out(proof, expected)
      pr = PR_URL.match(expected['pr_url'])[4]
      store(:carve_out, ChangeCarveOutStore).record(repo: expected['repo'], pr: pr, sha: expected['sha'], proof: proof,
                                                    policy_sha: policy_sha, recorded_by: @recorded_by)
      "carve-out for PR ##{pr} at #{expected['sha'][0, 12]}"
    end

    def write_release(proof, expected)
      store(:release, ChangeReleaseStore).record(repo: expected['repo'], tag: expected['tag'], sha: expected['sha'], proof: proof,
                                                 policy_sha: policy_sha, recorded_by: @recorded_by)
      "release #{expected['tag']} at #{expected['sha'][0, 12]}"
    end

    def approvals(sha) = @stores[:approval]&.call(sha) || ChangeApprovalStore.new(sha)

    def overrides(sha, profile) = @stores[:override]&.call(sha, profile) || ChangeOverrideStore.new(sha, profile: profile)

    def store(name, klass) = @stores[name] || klass.new
  end
end
