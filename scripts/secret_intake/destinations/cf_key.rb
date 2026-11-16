# frozen_string_literal: true

require_relative '../../cf_key_validator'
require_relative '../../cf_provider_registry'
require_relative '../../cf_secret_store'
require_relative 'errors'

module SecretIntake
  module Destinations
    # Enrolls a staged value as a provider key in the cf paid-key store at a
    # level (`--dir`, else the current project), the same write `cf_keys.rb
    # enroll` makes, so CfSecrets.resolve and every paid skill find it. A value
    # not already validated against this provider is validated first.
    class CfKey
      def initialize(project:, validator: CfKeyValidator.new)
        @project, @validator = project, validator
      end

      def push(name, value, provider:, validated_by:)
        raise ArgumentError, "unknown provider #{provider}" unless CfProviderRegistry.known?(provider)

        validate!(provider, value) unless validated_by == provider
        CfSecretStore.describe(@project)
        CfSecretStore.write_key(@project.slug, provider, value)
        CfSecretStore.update_meta(@project.slug) { |m| m['deferred']&.delete(provider) }
        [ "enrolled #{name} as the #{provider} key for #{@project.root}" ]
      end

      private

      def validate!(provider, value)
        result = @validator.call(provider, value)
        raise Invalid, "#{result.reason}; nothing enrolled" unless result.ok?
      end
    end
  end
end
