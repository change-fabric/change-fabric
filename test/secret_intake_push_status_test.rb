# frozen_string_literal: true

require_relative "secret_intake_helpers"

class SecretIntakePushStatusTest < Minitest::Test
  include SecretIntakeHelpers

  def staged(home)
    project = File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    store = SecretIntake::StagingStore.new(project: CfProjectIdentity.for(project))
    store.put("API_TOKEN", SENTINEL, validated_by: "none")
    [ project, store ]
  end

  def test_status_shows_push_history_never_values
    with_temp_home do |home|
      staged(home)
      cli = cli_for(FakeAws.new, home: home)
      assert_equal 0, cli.run(%w[push API_TOKEN --to env:.env.local])
      assert_equal 0, cli.run(%w[status])
      assert_match(%r{API_TOKEN: staged .*pushed to env:/\S+/\.env\.local}, @out.string)
      refute_includes @out.string + @err.string, SENTINEL
    end
  end

  def test_remove_deletes_the_file_and_meta
    with_temp_home do |home|
      _project, store = staged(home)
      path = File.join(store.dir, "API_TOKEN")
      cli = cli_for(FakeAws.new, home: home)
      assert_equal 0, cli.run(%w[remove API_TOKEN])
      refute File.exist?(path)
      assert_empty store.list
      assert_equal 1, cli.run(%w[remove API_TOKEN])
      assert_includes @err.string, "nothing staged as API_TOKEN"
    end
  end

  def test_push_needs_a_staged_name_and_a_known_destination_kind
    with_temp_home do |home|
      staged(home)
      cli = cli_for(FakeAws.new, home: home)
      assert_equal 1, cli.run(%w[push MISSING --to env:.env])
      assert_equal 1, cli.run(%w[push API_TOKEN --to vault:x])
      assert_equal 1, cli.run(%w[push API_TOKEN])
      refute_includes @out.string + @err.string, SENTINEL
    end
  end
end
