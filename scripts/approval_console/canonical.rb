# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

module ApprovalConsole
  # The canonical approval body: a JSON object with recursively sorted keys, no
  # insignificant whitespace and UTF-8 text. The WebAuthn challenge is the raw
  # SHA-256 of this exact string, so the authenticator signs a commitment to
  # everything the approver was shown. `validate` is the single definition of
  # a well-formed body; the verifier refuses anything that is not byte-for-byte
  # the canonical rendering of a valid one.
  module Canonical
    class Invalid < StandardError; end

    VERSION = 1
    TYPES = %w[step override prod-op carve-out money release].freeze
    SCOPES = %w[merge tag].freeze
    MAX_LIFETIME = 3600
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    SHA = /\A[0-9a-f]{40}\z/
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    COMMON = %w[v type machine_id repo sha profile request_id created_at expires_at].freeze
    PER_TYPE = {
      'step' => %w[items],
      'override' => %w[reason],
      'prod-op' => %w[summary argv],
      'money' => %w[summary argv],
      'carve-out' => %w[summary pr_url pr_title base files],
      'release' => %w[tag commit]
    }.freeze
    # Fields a body may omit: an override with no scope unlocks both the merge
    # and the tag guard; with one, only that guard. Absent equals nil when a
    # verifier compares a body to its expected context.
    OPTIONAL = { 'override' => %w[scope] }.freeze
    UNVERIFIED = 'unverified-'

    module_function

    def sort(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, sort(item) ] }.sort.to_h
      when Array then value.map { |item| sort(item) }
      when Symbol then value.to_s
      else value
      end
    end

    def serialize(value) = JSON.generate(sort(value))

    # True when the bytes are valid UTF-8, the only encoding a body may use.
    def utf8?(string) = string.is_a?(String) && string.dup.force_encoding(Encoding::UTF_8).valid_encoding?

    def challenge(body) = Digest::SHA256.digest(body.to_s.b)

    def body_sha256(body) = Digest::SHA256.hexdigest(body.to_s.b)

    # The same digest ChangeTrust.digest gives a step definition, so a body's
    # item digest is recomputed from its `fields` rather than trusted.
    def step_digest(fields)
      hex = Digest::SHA256.hexdigest(serialize(fields))
      fields.is_a?(Hash) && fields['files_error'] ? "#{UNVERIFIED}#{hex}" : hex
    end

    # Builds and returns the canonical body string. Item digests are computed
    # here from `fields`; callers pass only step, fields and base_fields.
    def build(attrs)
      body = attrs.to_h { |key, value| [ key.to_s, value ] }
      body['v'] = VERSION
      body['profile'] = nil unless body.key?('profile')
      body['items'] = body['items'].map { |item| with_digest(item) } if body['items'].is_a?(Array)
      errors = validate(sort(body))
      raise Invalid, errors.join('; ') unless errors.empty?

      serialize(body)
    end

    def with_digest(item)
      entry = item.to_h { |key, value| [ key.to_s, value ] }
      entry['base_fields'] = nil unless entry.key?('base_fields')
      entry['digest'] = step_digest(entry['fields'])
      entry
    end

    # Parses a canonical body string. Raises Invalid for malformed JSON, a
    # non-canonical rendering, or a body that fails `validate`.
    def parse(string)
      raise Invalid, 'body is not valid UTF-8' unless Canonical.utf8?(string)

      body = JSON.parse(string.to_s)
      raise Invalid, 'body is not a JSON object' unless body.is_a?(Hash)
      raise Invalid, 'body is not in canonical form' unless serialize(body) == string

      errors = validate(body)
      raise Invalid, errors.join('; ') unless errors.empty?

      body
    rescue JSON::ParserError, JSON::GeneratorError => e
      raise Invalid, "body is not valid JSON: #{e.message}"
    end

    def validate(body)
      type = body['type']
      return [ "unknown type #{type.inspect}" ] unless TYPES.include?(type)

      errors = []
      required = COMMON + PER_TYPE.fetch(type)
      allowed = required + OPTIONAL.fetch(type, [])
      errors << "unexpected fields: #{(body.keys - allowed).sort.join(', ')}" unless (body.keys - allowed).empty?
      errors << "missing fields: #{(required - body.keys).sort.join(', ')}" unless (required - body.keys).empty?
      errors.concat(common_errors(body))
      errors.concat(payload_errors(type, body))
      errors
    end

    def common_errors(body)
      errors = []
      errors << "unsupported version #{body['v'].inspect}" unless body['v'] == VERSION
      errors << 'machine_id is not a uuid' unless body['machine_id'].to_s.match?(UUID)
      errors << 'request_id is not a uuid' unless body['request_id'].to_s.match?(UUID)
      errors << 'sha is not 40 lowercase hex' unless body['sha'].to_s.match?(SHA)
      errors << 'repo is empty' unless nonempty?(body['repo'])
      errors << 'profile must be a string or null' unless body['profile'].nil? || nonempty?(body['profile'])
      errors.concat(lifetime_errors(body))
    end

    def lifetime_errors(body)
      created = parse_time(body['created_at'])
      expires = parse_time(body['expires_at'])
      return [ 'created_at and expires_at must be UTC ISO 8601 (YYYY-MM-DDTHH:MM:SSZ)' ] unless created && expires
      return [ 'expires_at must be after created_at' ] unless expires > created
      return [ "lifetime exceeds #{MAX_LIFETIME} seconds" ] if expires - created > MAX_LIFETIME

      []
    end

    def parse_time(value)
      return nil unless value.is_a?(String) && value.match?(TIME)

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def payload_errors(type, body)
      case type
      when 'step' then item_errors(body['items'])
      when 'override' then override_errors(body)
      when 'carve-out' then carve_out_errors(body)
      when 'release' then release_errors(body)
      else summary_errors(body) + argv_errors(body['argv'])
      end
    end

    def override_errors(body)
      errors = nonempty?(body['reason']) ? [] : [ 'reason is empty' ]
      errors << "scope must be one of #{SCOPES.join(', ')}" if body.key?('scope') && !SCOPES.include?(body['scope'])
      errors
    end

    def carve_out_errors(body)
      errors = summary_errors(body)
      errors << 'pr_url is not an https URL' unless body['pr_url'].to_s.match?(%r{\Ahttps://\S+\z})
      errors << 'pr_title is empty' unless nonempty?(body['pr_title'])
      errors << 'base is empty' unless nonempty?(body['base'])
      files = body['files']
      errors << 'files must be a sorted, unique array of non-empty strings' unless files.is_a?(Array) && files.all? { |f| nonempty?(f) } && files == files.uniq.sort
      errors
    end

    def release_errors(body)
      errors = []
      errors << 'tag is empty' unless nonempty?(body['tag'])
      errors << 'commit must equal sha' unless body['commit'] == body['sha']
      errors
    end

    def summary_errors(body) = nonempty?(body['summary']) ? [] : [ 'summary is empty' ]

    def argv_errors(argv)
      ok = argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) }
      ok ? [] : [ 'argv must be a non-empty array of strings' ]
    end

    def item_errors(items)
      return [ 'items must be a non-empty array' ] unless items.is_a?(Array) && !items.empty?

      items.flat_map do |item|
        next [ 'item is not an object' ] unless item.is_a?(Hash)

        errors = []
        errors << 'item step is empty' unless nonempty?(item['step'])
        errors << 'item is missing base_fields' unless item.key?('base_fields')
        errors << 'item fields must be an object' unless item['fields'].is_a?(Hash)
        errors << 'item digest does not match its fields' unless item['fields'].is_a?(Hash) && item['digest'] == step_digest(item['fields'])
        base = item['base_fields']
        errors << 'item base_fields must be an object or null' unless base.nil? || base.is_a?(Hash)
        errors
      end
    end

    def nonempty?(value) = value.is_a?(String) && !value.strip.empty?
  end
end
