# frozen_string_literal: true

require_relative '../aws_runner'
require_relative 'errors'

module SecretIntake
  module Destinations
    # Writes a SecureString parameter. Before anything is written it prints
    # the live account id, alias and parameter path, refuses unless
    # `confirm_account` equals the live `sts get-caller-identity` account, and
    # refuses when the parameter exists unless `overwrite` is set. The value
    # goes only into a 0600 `--cli-input-json` file, never argv.
    class Ssm
      ACCOUNT_SHAPE = /\A\d{12}\z/
      NOT_FOUND = /ParameterNotFound/

      def initialize(aws:, say:)
        @aws, @say = aws, say
      end

      def push(name, value, param:, confirm_account:, overwrite: false)
        raise ArgumentError, "ssm parameter must start with /, got #{param}" unless param.start_with?('/')

        account = confirm!(param, confirm_account)
        exists = exists?(param)
        raise Refused, "#{param} already exists in #{account}; pass --overwrite to write a new version" if exists && !overwrite

        @aws.with_input_json('Name' => param, 'Value' => value, 'Type' => 'SecureString', 'Overwrite' => exists) do |ref|
          @aws.call!('ssm', 'put-parameter', '--cli-input-json', ref)
        end
        [ "#{exists ? 'wrote a new version of' : 'created'} #{param} (SecureString) in #{account} for #{name}" ]
      end

      private

      def confirm!(param, confirm_account)
        account = @aws.json!('sts', 'get-caller-identity')['Account'].to_s
        @say.call("ssm target: account #{account} (#{account_alias}), region #{@aws.region}, parameter #{param}")
        unless confirm_account.to_s.match?(ACCOUNT_SHAPE) && confirm_account == account
          raise Refused, "--confirm-account #{confirm_account || '(missing)'} does not match the live account " \
                         "#{account}; ask the user to confirm the account, then pass it"
        end
        account
      end

      def account_alias
        Array(@aws.json!('iam', 'list-account-aliases')['AccountAliases']).first || 'no alias'
      rescue AwsError, JSON::ParserError
        'alias unknown'
      end

      # Metadata only: no --with-decryption, so the stored value never comes back.
      def exists?(param)
        result = @aws.call('ssm', 'get-parameter', '--name', param)
        return true if result.ok?
        return false if result.err.match?(NOT_FOUND)

        raise AwsError, AwsRunner.failure_message(%w[ssm get-parameter], result)
      end
    end
  end
end
