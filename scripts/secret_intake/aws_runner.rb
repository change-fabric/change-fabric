# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'secret_file'

module SecretIntake
  # Any failed `aws` call. The message carries the subcommand and the CLI's
  # first stderr line, never argv values beyond the subcommand.
  class AwsError < StandardError; end

  # Runs the host `aws` CLI with a fixed profile and region. Arguments go in an
  # argv array (no shell), and anything secret goes through a 0600 temp file
  # instead of argv, so a process listing never shows it.
  class AwsRunner
    Result = Struct.new(:out, :err, :ok) do
      def ok? = ok
    end

    attr_reader :profile, :region

    # `executor` takes an argv array and returns [stdout, stderr, status];
    # tests inject a fake that records argv.
    def initialize(profile:, region:, executor: Open3.method(:capture3))
      @profile, @region, @executor = profile, region, executor
    end

    def call(*args)
      out, err, status = @executor.call('aws', *args, '--profile', @profile, '--region', @region)
      Result.new(out.to_s, err.to_s, status.respond_to?(:success?) ? status.success? : status)
    end

    # Calls and raises AwsError on failure; returns stdout.
    def call!(*args)
      result = call(*args)
      raise AwsError, failure(args, result) unless result.ok?

      result.out
    end

    def json!(*args)
      out = call!(*args)
      out.strip.empty? ? {} : JSON.parse(out)
    end

    # Yields a `file://` reference to a 0600 temp file holding hash as JSON, for
    # `--cli-input-json`. The file is overwritten with zeros and removed after.
    def with_input_json(hash)
      SecretFile.with(JSON.generate(hash)) { |path| yield "file://#{path}" }
    end

    private

    def failure(args, result)
      line = result.err.lines.map(&:strip).reject(&:empty?).first || 'no error output'
      "aws #{args.take(2).join(' ')} failed: #{line}"
    end
  end
end
