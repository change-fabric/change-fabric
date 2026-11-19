# frozen_string_literal: true

require_relative 'console'
require_relative 'store'
require_relative 'clients'

# Lambda entry for the function URL. A function URL event always carries
# requestContext; a direct invoke does not, and only an IAM-authorized caller
# can send one, which is how the deploy script self-tests KMS under the deployed
# role: decrypt a ciphertext the script made under a throwaway machine_id context
# and sign a constant. The table is untouched.
def handler(event:, context:)
  return selftest(event) if event.is_a?(Hash) && event['cf_selftest'] && !event.key?('requestContext')

  app.call(event)
end

def app
  $console_app ||= ApprovalConsoleApp.new(store: DynamoStore.new, kms: ConsoleKms.new, dm: ConsoleDm.new, logger: ->(line) { puts line })
end

def selftest(event, kms: ConsoleKms.new)
  context = { 'machine_id' => event['machine_id'].to_s }
  plain = kms.decrypt(Base64.decode64(event['ciphertext'].to_s), context)
  decrypted = plain == Base64.decode64(event['expect'].to_s)
  signature, = kms.sign('cf-selftest')
  { ok: decrypted && !signature.empty?, decrypt: decrypted, sign: !signature.empty? }
end
