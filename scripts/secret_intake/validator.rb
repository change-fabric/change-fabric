# frozen_string_literal: true

require_relative '../cf_key_validator'
require_relative '../cf_provider_registry'

module SecretIntake
  # Checks an arrived value against a provider's free endpoint
  # (config/providers.yml), or skips the check for `none`. The value stays in
  # memory; CfKeyValidator puts it only in the request header.
  class Validator
    NONE = 'none'

    def initialize(key_validator: CfKeyValidator.new)
      @key_validator = key_validator
    end

    def self.known?(provider) = provider == NONE || CfProviderRegistry.known?(provider)

    def call(provider, value)
      return CfKeyValidator::Result.new(true, 'not validated') if provider == NONE

      @key_validator.call(provider, value)
    end
  end
end
