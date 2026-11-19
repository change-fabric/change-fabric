# frozen_string_literal: true

require 'base64'
require 'json'
require 'open3'
require 'openssl'
require 'tempfile'

module ApprovalConsole
  # The few AWS calls `enroll` makes with the human's own profile, through the
  # aws CLI (no SDK dependency on the machine): read the console function's
  # configuration, seed the machine rows and the bootstrap token with
  # conditional puts, encrypt the TOTP seed under the machine_id context, read
  # the passkey credential rows, and fetch the receipt public key. Never used by
  # the console itself, and never on a path an agent can reach (enroll is
  # human-only).
  class AwsOperator
    class Failed < StandardError; end

    # runner: (argv) -> [stdout, success?, stderr]
    def initialize(profile:, region:, runner: nil)
      @profile = profile
      @region = region
      @runner = runner || method(:capture)
    end

    # { 'TABLE_NAME', 'SEED_KEY_ID', 'RECEIPT_KEY_ID', ... } from the function.
    def function_env(name)
      out = aws('lambda', 'get-function-configuration', '--function-name', name, '--query', 'Environment.Variables', '--output', 'json')
      data = JSON.parse(out)
      raise Failed, "function #{name} has no environment" unless data.is_a?(Hash) && data['TABLE_NAME']

      data
    end

    # The function URL the deployed function answers on, for the rpId check.
    def function_url(name)
      aws('lambda', 'get-function-url-config', '--function-name', name, '--query', 'FunctionUrl', '--output', 'text').strip
    end

    # A conditional put that never replaces: :created, or :exists when an item
    # with that key is already there.
    def put_new(table, item)
      aws('dynamodb', 'put-item', '--table-name', table, '--item', JSON.generate(marshal(item)),
          '--condition-expression', 'attribute_not_exists(pk)')
      :created
    rescue Failed => e
      raise unless e.message.include?('ConditionalCheckFailed')

      :exists
    end

    # The seed encrypted under the machine_id context, as base64url (the shape
    # the console's SEED row holds). The plaintext goes through a 0600 temp
    # file in `dir` (the protected store), removed at once.
    def encrypt_seed(key_id, seed, machine_id, dir:)
      # Tempfile.create opens with O_EXCL and mode 0600.
      Tempfile.create('seed', dir) do |file|
        file.binmode
        file.write(seed)
        file.flush
        out = aws('kms', 'encrypt', '--key-id', key_id, '--encryption-context', "machine_id=#{machine_id}",
                  '--plaintext', "fileb://#{file.path}", '--query', 'CiphertextBlob', '--output', 'text')
        Base64.urlsafe_encode64(Base64.strict_decode64(out.strip), padding: false)
      end
    end

    # { credential_id => cose (base64url) } from the CRED rows.
    def credentials(table)
      out = aws('dynamodb', 'query', '--table-name', table, '--consistent-read', '--key-condition-expression', 'pk = :p',
                '--expression-attribute-values', JSON.generate(marshal(':p' => 'CRED')), '--output', 'json')
      Array(JSON.parse(out)['Items']).to_h { |item| [ item.dig('sk', 'S'), item.dig('cose', 'S') ] }
    end

    def receipt_public_pem(key_id)
      out = aws('kms', 'get-public-key', '--key-id', key_id, '--query', 'PublicKey', '--output', 'text')
      OpenSSL::PKey.read(Base64.strict_decode64(out.strip)).public_to_pem
    end

    private

    def marshal(item)
      item.compact.to_h do |key, value|
        [ key, value.is_a?(Integer) ? { 'N' => value.to_s } : { 'S' => value.to_s } ]
      end
    end

    def aws(*args)
      argv = [ 'aws', *args, '--profile', @profile, '--region', @region ]
      out, ok, err = @runner.call(argv)
      raise Failed, "#{args.first(2).join(' ')} failed: #{err.to_s.strip[0, 300]}" unless ok

      out
    end

    def capture(argv)
      out, err, status = Open3.capture3(*argv)
      [ out, status.success?, err ]
    end
  end
end
