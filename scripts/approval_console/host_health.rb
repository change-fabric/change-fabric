# frozen_string_literal: true

require_relative 'local_store'

module ApprovalConsole
  # Whether this host has a protected store for the TOTP seed: the store
  # directories exist, are 0700 and owned by the current user, the seed file is
  # 0600, and the read guard that keeps agent tools out of the store is
  # installed. A degraded host still approves ordinary types with TOTP and
  # refuses the high-risk ones.
  module HostHealth
    HIGH_RISK = %w[prod-op carve-out money release override run-script grant].freeze
    GUARD = File.join('.claude', 'cf', 'bin', 'secrets_read_guard.rb')

    Report = Struct.new(:reasons, keyword_init: true) do
      def degraded? = !reasons.empty?
    end

    module_function

    def check(store: LocalStore.new, home: ENV.fetch('HOME', Dir.home))
      reasons = []
      reasons.concat(dir_reasons(store))
      reasons.concat(seed_reasons(store))
      reasons << "the secrets read guard is not installed at ~/#{GUARD}" unless File.file?(File.join(home, GUARD))
      Report.new(reasons: reasons)
    end

    # nil when the type may proceed, else a message naming what is degraded.
    def refusal(type, report)
      return nil unless HIGH_RISK.include?(type) && report.degraded?

      "refusing #{type} approval on a degraded host: #{report.reasons.join('; ')}"
    end

    def dir_reasons(store)
      [ CfSecretStore.root, CfSecretStore.dir(store.slug), store.dir ].flat_map do |dir|
        next [ "#{dir} is missing" ] unless File.directory?(dir)

        stat = File.stat(dir)
        reasons = []
        reasons << "#{dir} has mode #{format('%o', stat.mode & 0o777)}, not 700" unless (stat.mode & 0o777) == LocalStore::DIR_MODE
        reasons << "#{dir} is not owned by the current user" unless stat.uid == Process.uid
        reasons
      end
    end

    def seed_reasons(store)
      return [] unless store.enrolled?

      mode = File.stat(store.path('totp_seed')).mode & 0o777
      mode == LocalStore::FILE_MODE ? [] : [ "the TOTP seed has mode #{format('%o', mode)}, not 600" ]
    end
  end
end
