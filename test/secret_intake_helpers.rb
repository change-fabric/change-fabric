# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/secret_intake"

# Shared fakes for the secret_intake tests. Nothing here reaches AWS.
module SecretIntakeHelpers
  SENTINEL = "sk-SENTINEL-do-not-print-0123456789abcdef"
  CREDENTIALS = { "Version" => 1, "AccessKeyId" => "ASIAFAKEFAKEFAKE", "SecretAccessKey" => "fake/secret/key",
                  "SessionToken" => "FAKE-SESSION-TOKEN", "Expiration" => "2099-01-01T00:00:00Z" }.freeze

  # Stands in for AwsRunner. Records every argv and answers by subcommand:
  # `responses` maps a subcommand name (e.g. "head-object") to a Result or to a
  # list of Results consumed in order (the last one repeats). get-object writes
  # `upload` to the path it is given, as the real CLI does.
  class FakeAws
    Result = SecretIntake::AwsRunner::Result

    attr_reader :calls, :profile, :region

    def initialize(responses: {}, upload: SENTINEL, region: "us-east-1")
      @responses, @upload, @region, @profile, @calls = responses, upload, region, "personal", []
    end

    def call(*args)
      @calls << args
      name = args[1]
      File.write(args.last, @upload) if name == "get-object" && @upload
      answer(name)
    end

    def call!(*args)
      result = call(*args)
      raise SecretIntake::AwsError, "aws #{args.take(2).join(' ')} failed: #{result.err}" unless result.ok?

      result.out
    end

    def subcommands = @calls.map { |args| args[1] }

    private

    def answer(name)
      canned = @responses[name]
      return Result.new(name == "export-credentials" ? JSON.generate(CREDENTIALS) : "{}", "", true) unless canned
      return canned unless canned.is_a?(Array)

      canned.size > 1 ? canned.shift : canned.first
    end
  end

  def ok(out = "{}") = SecretIntake::AwsRunner::Result.new(out, "", true)

  def fail_with(err) = SecretIntake::AwsRunner::Result.new("", err, false)

  def not_found = fail_with("An error occurred (404) when calling the HeadObject operation: Not Found")

  # A validator double: ok unless told otherwise, and records what it saw.
  class FakeValidator
    attr_reader :seen

    def initialize(ok: true) = @ok = ok

    def call(provider, value)
      @seen = [ provider, value ]
      CfKeyValidator::Result.new(@ok, @ok ? "HTTP 200" : "#{provider} rejected the key (HTTP 401)")
    end
  end

  def with_temp_home
    home = Dir.mktmpdir
    prev = ENV["HOME"]
    ENV["HOME"] = home
    yield home
  ensure
    ENV["HOME"] = prev
    FileUtils.remove_entry(home)
  end

  # A CLI on fakes whose poller never sleeps, with signal traps off unless asked.
  def cli_for(aws, home:, validator: FakeValidator.new, poller: nil, traps: false, clock: -> { Time.utc(2030, 1, 1, 12) })
    @out, @err = StringIO.new, StringIO.new
    project = File.join(home, "project")
    FileUtils.mkdir_p(project)
    SecretIntake::CLI.new(stdout: @out, stderr: @err, cwd: project, aws_factory: ->(_p, _r) { aws },
                          poller: poller || SecretIntake::Poller.new(clock: clock, sleeper: ->(_) { }),
                          validator: validator, clock: clock, traps: traps,
                          bucket_factory: ->(a, name) { SecretIntake::IntakeBucket.new(aws: a, project: name, hex: -> { "abcd1234" }) })
  end
end
