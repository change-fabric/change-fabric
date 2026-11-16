# frozen_string_literal: true

module SecretIntake
  module Destinations
    # A push the CLI refuses before any write: an SSM account that does not
    # match --confirm-account, or an existing parameter without --overwrite.
    class Refused < StandardError; end

    # A local write that failed (unwritable env file, failed rename). The
    # original file is unchanged and the backup, when one was taken, is kept.
    class WriteFailed < StandardError; end

    # A value the provider rejected when enrolling it as a cf key.
    class Invalid < StandardError; end
  end
end
