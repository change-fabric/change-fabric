# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative '../cf_secret_store'
require_relative 'secret_file'

module SecretIntake
  # Staged secrets for one project, inside the store CfSecretStore owns: a
  # `staged/` folder beside the provider key files, one 0600 file per name, and
  # a value-free `staged` entry in meta.json (staged_at, validated_by, pushes).
  # Staged values stay until `remove`.
  class StagingStore
    NAME_SHAPE = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

    def self.valid_name?(name) = name.to_s.match?(NAME_SHAPE)

    def initialize(project:, clock: -> { Time.now.utc })
      @project, @clock = project, clock
    end

    def dir = File.join(CfSecretStore.dir(@project.slug), 'staged')

    def put(name, value, validated_by:)
      path = path_for(name)
      CfSecretStore.ensure_dir(@project.slug)
      FileUtils.mkdir_p(dir, mode: CfSecretStore::DIR_MODE)
      File.chmod(CfSecretStore::DIR_MODE, dir)
      CfSecretStore.atomic_write(path, value)
      CfSecretStore.describe(@project)
      CfSecretStore.update_meta(@project.slug) do |m|
        (m['staged'] ||= {})[name] = { 'staged_at' => @clock.call.iso8601, 'validated_by' => validated_by, 'pushes' => [] }
      end
      path
    end

    # For the CLI's push verbs only; never printed.
    def read(name)
      path = path_for(name)
      File.file?(path) ? File.read(path) : nil
    end

    # [name, entry] pairs from meta.json; no value is read.
    def list
      entries = CfSecretStore.meta(@project.slug)['staged']
      entries.is_a?(Hash) ? entries.sort : []
    end

    def record_push(name, destination)
      CfSecretStore.update_meta(@project.slug) do |m|
        entry = m.dig('staged', name) or next
        (entry['pushes'] ||= []) << { 'to' => destination, 'at' => @clock.call.iso8601 }
      end
    end

    def remove(name)
      path = path_for(name)
      SecretFile.shred(path)
      CfSecretStore.update_meta(@project.slug) { |m| m['staged']&.delete(name) }
    end

    private

    def path_for(name)
      raise ArgumentError, "invalid secret name #{name.inspect}" unless self.class.valid_name?(name)

      File.join(dir, name)
    end
  end
end
