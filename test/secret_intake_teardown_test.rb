# frozen_string_literal: true

require_relative "secret_intake_helpers"

# Every exit path of intake deletes the bucket.
class SecretIntakeTeardownTest < Minitest::Test
  include SecretIntakeHelpers

  ARGV_INTAKE = %w[intake --name OPENAI_API_KEY].freeze

  def torn_down?(aws) = aws.subcommands.last(2) == %w[rm delete-bucket]

  def test_success_stages_and_tears_down
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "head-object" => [ not_found, ok ] })
      assert_equal 0, cli_for(aws, home: home).run(ARGV_INTAKE)
      assert torn_down?(aws)
      assert_includes @out.string, "staged OPENAI_API_KEY"
      assert_includes @out.string, "intake bucket deleted"
    end
  end

  def test_validation_failure_stages_nothing_and_tears_down
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "head-object" => ok })
      code = cli_for(aws, home: home, validator: FakeValidator.new(ok: false)).run(ARGV_INTAKE + %w[--validate openai])
      assert_equal 3, code
      assert torn_down?(aws)
      assert_empty Dir.glob(File.join(home, ".claude/cf/secrets/*/staged/*"))
    end
  end

  def test_empty_upload_is_a_validation_failure
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "head-object" => ok }, upload: "  \n")
      assert_equal 3, cli_for(aws, home: home).run(ARGV_INTAKE)
      assert torn_down?(aws)
    end
  end

  def test_aws_failure_mid_poll_tears_down
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "head-object" => fail_with("ExpiredToken: the SSO session expired") })
      assert_equal 5, cli_for(aws, home: home).run(ARGV_INTAKE)
      assert torn_down?(aws)
      assert_includes @err.string, "ExpiredToken"
    end
  end

  def test_aws_failure_during_create_still_tears_down_what_exists
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "put-bucket-encryption" => fail_with("AccessDenied") })
      assert_equal 5, cli_for(aws, home: home).run(ARGV_INTAKE)
      assert torn_down?(aws)
    end
  end

  def test_timeout_tears_down_and_exits_4
    with_temp_home do |home|
      ticks = [ Time.utc(2030, 1, 1, 12, 10), Time.utc(2030, 1, 1, 14) ]
      poller = SecretIntake::Poller.new(clock: -> { ticks.size > 1 ? ticks.shift : ticks.first }, sleeper: ->(_) {})
      aws = FakeAws.new(responses: { "head-object" => not_found })
      assert_equal 4, cli_for(aws, home: home, poller: poller).run(ARGV_INTAKE)
      assert torn_down?(aws)
      assert_includes @err.string, "nothing staged"
    end
  end

  def test_interrupt_tears_down
    with_temp_home do |home|
      poller = Object.new
      def poller.wait(_deadline) = raise(Interrupt)
      aws = FakeAws.new
      assert_equal 130, cli_for(aws, home: home, poller: poller).run(ARGV_INTAKE)
      assert torn_down?(aws)
    end
  end

  def test_teardown_failure_turns_success_into_exit_5_with_manual_command
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "head-object" => ok, "delete-bucket" => fail_with("ExpiredToken") })
      assert_equal 5, cli_for(aws, home: home).run(ARGV_INTAKE)
      assert_includes @err.string, "aws s3 rb s3://project-key-intake-abcd1234 --force"
    end
  end

  def test_bad_name_or_provider_never_creates_a_bucket
    with_temp_home do |home|
      aws = FakeAws.new
      assert_equal 1, cli_for(aws, home: home).run(%w[intake --name 1BAD])
      assert_equal 1, cli_for(aws, home: home).run(ARGV_INTAKE + %w[--validate nope])
      assert_equal 1, cli_for(aws, home: home).run(ARGV_INTAKE + %w[--ttl 13h])
      assert_empty aws.calls
    end
  end

  def test_signal_traps_raise_interrupt_into_the_body
    with_temp_home do |home|
      poller = Object.new
      def poller.wait(_deadline)
        Process.kill("TERM", Process.pid)
        sleep 5
        true
      end
      aws = FakeAws.new
      assert_equal 130, cli_for(aws, home: home, poller: poller, traps: true).run(ARGV_INTAKE)
      assert torn_down?(aws)
    end
  end
end
