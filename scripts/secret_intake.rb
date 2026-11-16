#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'tempfile'
require 'time'
require_relative 'cf_project_identity'
require_relative 'change_artifacts_config'
require_relative 'secret_intake/aws_runner'
require_relative 'secret_intake/intake_bucket'
require_relative 'secret_intake/page_renderer'
require_relative 'secret_intake/poller'
require_relative 'secret_intake/presigner'
require_relative 'secret_intake/redactor'
require_relative 'secret_intake/secret_file'
require_relative 'secret_intake/staging_store'
require_relative 'secret_intake/validator'

module SecretIntake
  # Stages a secret by upload page and reports on what is staged. Prints status
  # lines only: the page link once, then names, never a value.
  #
  #   intake --name NAME [--profile P] [--region R] [--validate PROVIDER|none] [--ttl 1h]
  #   status
  #
  # intake makes a private bucket in the user's AWS account, uploads a
  # one-field page holding a signed PUT URL, prints the signed page link once,
  # waits for the upload, validates it, stages it in the cf secret store, and
  # deletes the bucket on every exit path. kill -9 skips the teardown; the
  # bucket's 1-day expiry rule is the backstop.
  class CLI
    USAGE = 'usage: secret_intake.rb intake --name NAME [--profile P] [--region R] ' \
            '[--validate PROVIDER|none] [--ttl 1h] | status'
    EXIT_USAGE = 1
    EXIT_INVALID = 3
    EXIT_TIMEOUT = 4
    EXIT_AWS = 5
    EXIT_INTERRUPTED = 130
    DEFAULT_TTL = 3600
    MAX_TTL = 43_200
    TTL_SHAPE = /\A(\d+)([smh])\z/
    TTL_UNITS = { 's' => 1, 'm' => 60, 'h' => 3600 }.freeze

    # Every collaborator is injectable; the defaults are the real ones.
    def initialize(stdout: $stdout, stderr: $stderr, cwd: Dir.pwd, aws_factory: nil, bucket_factory: nil,
                   presigner_factory: nil, renderer: PageRenderer.new, poller: Poller.new, validator: Validator.new,
                   clock: -> { Time.now.utc }, traps: true)
      @out, @err, @cwd = stdout, stderr, cwd
      @aws_factory = aws_factory || ->(profile, region) { AwsRunner.new(profile: profile, region: region) }
      @bucket_factory = bucket_factory || ->(aws, project) { IntakeBucket.new(aws: aws, project: project) }
      @presigner_factory = presigner_factory || method(:default_presigner)
      @renderer, @poller, @validator, @clock, @traps = renderer, poller, validator, clock, traps
      @redactor = Redactor.new
    end

    def run(argv)
      command, opts = parse(argv)
      case command
      when 'intake' then intake(opts)
      when 'status' then status
      else usage
      end
    rescue OptionParser::ParseError, ArgumentError => e
      say_err("secret_intake: #{e.message}")
      EXIT_USAGE
    end

    private

    def parse(argv)
      args = argv.dup
      opts = { profile: ChangeArtifactsConfig::DEFAULT_PROFILE, region: ChangeArtifactsConfig::DEFAULT_REGION,
               validate: Validator::NONE, ttl: DEFAULT_TTL }
      OptionParser.new do |o|
        o.on('--name NAME') { |v| opts[:name] = v }
        o.on('--profile PROFILE') { |v| opts[:profile] = v }
        o.on('--region REGION') { |v| opts[:region] = v }
        o.on('--validate PROVIDER') { |v| opts[:validate] = v }
        o.on('--ttl DURATION') { |v| opts[:ttl] = ttl_seconds(v) }
      end.parse!(args)
      [ args.first, opts ]
    end

    def ttl_seconds(text)
      match = TTL_SHAPE.match(text.to_s) or raise ArgumentError, "--ttl takes a duration like 30m or 2h, got #{text}"
      seconds = match[1].to_i * TTL_UNITS.fetch(match[2])
      raise ArgumentError, '--ttl must be between 1m and 12h' unless seconds.between?(60, MAX_TTL)

      seconds
    end

    def usage
      say_err(USAGE)
      EXIT_USAGE
    end

    def project = @project ||= CfProjectIdentity.for(@cwd)

    def store = StagingStore.new(project: project, clock: @clock)

    def intake(opts)
      return usage unless StagingStore.valid_name?(opts[:name])
      raise ArgumentError, "unknown --validate provider #{opts[:validate]}" unless Validator.known?(opts[:validate])

      aws = @aws_factory.call(opts[:profile], opts[:region])
      bucket = @bucket_factory.call(aws, File.basename(project.root))
      with_signal_traps { intake_body(aws, bucket, opts) }
    end

    # The whole body runs inside ensure-teardown; INT and TERM raise into it.
    # A teardown failure turns an otherwise clean exit into EXIT_AWS.
    def intake_body(aws, bucket, opts)
      code = nil
      begin
        code = staged_exit(aws, bucket, opts)
      rescue Interrupt
        say_err('secret_intake: interrupted')
        code = EXIT_INTERRUPTED
      rescue StandardError => e
        say_err("secret_intake: #{e.message}")
        code = EXIT_AWS
      ensure
        teardown_code = teardown(bucket)
      end
      teardown_code && code.to_i.zero? ? teardown_code : code
    end

    def staged_exit(aws, bucket, opts)
      presigner = @presigner_factory.call(aws)
      expires = presigner.expires_for(opts[:ttl])
      say("note: the link lasts #{expires / 60}m, capped by the AWS session") if expires < opts[:ttl]
      bucket.create!
      put_url = presigner.url('PUT', bucket.name, IntakeBucket::OBJECT_KEY, expires: expires)
      @redactor.add(put_url).add(put_url[/X-Amz-Signature=(\h+)/, 1])
      get_url = presigner.url('GET', bucket.name, IntakeBucket::PAGE_KEY, expires: expires)
      deadline = @clock.call + expires
      bucket.upload_page(@renderer.render(put_url: put_url, name: opts[:name], expires_at: deadline))
      say("open this link and paste #{opts[:name]} (for you only; expires #{deadline.strftime('%H:%M UTC')}):")
      @out.puts(get_url)
      @out.flush if @out.respond_to?(:flush)
      return timed_out unless @poller.wait(deadline) { bucket.arrived? }

      receive(bucket, opts)
    end

    def timed_out
      say_err('secret_intake: no upload before the link expired; nothing staged')
      EXIT_TIMEOUT
    end

    # Downloads to a 0600 temp, validates, stages, and shreds the temp.
    def receive(bucket, opts)
      value = SecretFile.with do |path|
        bucket.download(path)
        File.binread(path).force_encoding(Encoding::UTF_8).strip
      end
      @redactor.add(value)
      say('upload received')
      return invalid('the upload was empty') if value.empty?

      result = @validator.call(opts[:validate], value)
      return invalid(result.reason) unless result.ok?

      store.put(opts[:name], value, validated_by: opts[:validate])
      say("staged #{opts[:name]} for #{project.root} (validation: #{opts[:validate]})")
      0
    end

    def invalid(reason)
      say_err("secret_intake: #{reason}; nothing staged")
      EXIT_INVALID
    end

    def teardown(bucket)
      bucket.teardown
      say('intake bucket deleted') if bucket.name
      nil
    rescue StandardError => e
      say_err("secret_intake: #{e.is_a?(TeardownError) ? e.message : bucket.manual_delete}")
      EXIT_AWS
    end

    def with_signal_traps
      return yield unless @traps

      previous = %w[INT TERM].to_h { |sig| [ sig, trap(sig) { raise Interrupt } ] }
      yield
    ensure
      previous&.each { |sig, handler| trap(sig, handler || 'DEFAULT') }
    end

    def status
      entries = store.list
      @out.puts("#{project.root}: #{entries.empty? ? 'nothing staged' : "#{entries.size} staged"}")
      entries.each { |name, entry| @out.puts("  #{name}: #{describe(entry)}") }
      0
    end

    def describe(entry)
      parts = [ "staged #{age(entry['staged_at'])} ago", "validation: #{entry['validated_by']}" ]
      pushes = Array(entry['pushes']).map { |push| push['to'] }
      parts << "pushed to #{pushes.join(', ')}" unless pushes.empty?
      parts.join(', ')
    end

    def age(iso)
      seconds = (@clock.call - Time.parse(iso.to_s)).to_i
      return "#{seconds / 86_400}d" if seconds >= 86_400
      return "#{seconds / 3600}h" if seconds >= 3600

      "#{[ seconds / 60, 0 ].max}m"
    rescue ArgumentError
      'an unknown time'
    end

    def say(message) = @out.puts(@redactor.scrub(message))

    def say_err(message) = @err.puts(@redactor.scrub(message))

    def default_presigner(aws)
      json = aws.call!('configure', 'export-credentials', '--format', 'process')
      Presigner.new(credentials: Presigner.credentials_from(json), region: aws.region, clock: @clock)
    rescue AwsError
      raise AwsError, 'aws configure export-credentials failed: needs AWS CLI v2.13 or later and a live session ' \
                      "(aws sso login --profile #{aws.profile})"
    end
  end
end

exit(SecretIntake::CLI.new.run(ARGV)) if $PROGRAM_NAME == __FILE__
