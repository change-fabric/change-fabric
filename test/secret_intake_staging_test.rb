# frozen_string_literal: true

require_relative "secret_intake_helpers"

class SecretIntakeStagingTest < Minitest::Test
  include SecretIntakeHelpers

  NOW = Time.utc(2030, 1, 1, 12)

  def store_in(home)
    project = CfProjectIdentity.for_explicit_dir(File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) })
    SecretIntake::StagingStore.new(project: project, clock: -> { NOW })
  end

  def test_put_writes_a_0600_file_and_value_free_meta
    with_temp_home do |home|
      store = store_in(home)
      path = store.put("API_TOKEN", SENTINEL, validated_by: "none")
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(store.dir).mode & 0o777
      assert_equal SENTINEL, store.read("API_TOKEN")
      meta = File.read(File.join(File.dirname(store.dir), "meta.json"))
      refute_includes meta, SENTINEL
      assert_equal [ [ "API_TOKEN", { "staged_at" => NOW.iso8601, "validated_by" => "none", "pushes" => [] } ] ],
                   store.list
    end
  end

  def test_staged_folder_does_not_collide_with_provider_keys
    with_temp_home do |home|
      store = store_in(home)
      slug = File.basename(File.dirname(store.dir))
      CfSecretStore.write_key(slug, "openai", "sk-provider")
      store.put("OPENAI_API_KEY", SENTINEL, validated_by: "openai")
      assert_equal "sk-provider", CfSecretStore.read_key(slug, "openai")
      assert CfSecretStore.meta(slug).dig("enrolled", "openai")
    end
  end

  def test_record_push_and_remove
    with_temp_home do |home|
      store = store_in(home)
      path = store.put("API_TOKEN", SENTINEL, validated_by: "none")
      store.record_push("API_TOKEN", "env:.env.local")
      assert_equal [ { "to" => "env:.env.local", "at" => NOW.iso8601 } ], store.list.first[1]["pushes"]
      store.remove("API_TOKEN")
      refute File.exist?(path)
      assert_empty store.list
    end
  end

  def test_rejects_names_that_could_escape_the_folder
    with_temp_home do |home|
      assert_raises(ArgumentError) { store_in(home).put("../x", "v", validated_by: "none") }
    end
  end

  def test_status_prints_names_and_ages_only
    with_temp_home do |home|
      project = CfProjectIdentity.for(File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) })
      SecretIntake::StagingStore.new(project: project, clock: -> { NOW - 7200 })
                                .put("API_TOKEN", SENTINEL, validated_by: "openai")
      cli = cli_for(FakeAws.new, home: home, clock: -> { NOW })
      assert_equal 0, cli.run(%w[status])
      assert_includes @out.string, "1 staged"
      assert_includes @out.string, "API_TOKEN: staged 2h ago, validation: openai"
      refute_includes @out.string, SENTINEL
    end
  end
end
