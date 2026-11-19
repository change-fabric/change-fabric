# frozen_string_literal: true

# One implementation on both sides: the Lambda uses the same canonical body,
# CBOR, TOTP and verifier code as the CLI. In the package build.sh copies them
# into shared/; in a checkout they are read from scripts/approval_console/.
module ConsoleShared
  DIR = [
    File.join(__dir__, 'shared'),
    File.expand_path('../../../scripts/approval_console', __dir__)
  ].find { |dir| File.file?(File.join(dir, 'verifier.rb')) } || raise('shared approval_console files are missing')
end

%w[canonical cbor totp verifier].each { |name| require File.join(ConsoleShared::DIR, name) }
