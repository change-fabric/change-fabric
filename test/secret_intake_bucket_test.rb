# frozen_string_literal: true

require_relative "secret_intake_helpers"

class SecretIntakeBucketTest < Minitest::Test
  include SecretIntakeHelpers

  def bucket(aws, project: "My Project", hexes: %w[abcd1234 ef567890])
    SecretIntake::IntakeBucket.new(aws: aws, project: project, hex: -> { hexes.shift })
  end

  def test_create_runs_in_order_with_locked_down_settings
    aws = FakeAws.new
    name = bucket(aws).create!
    assert_equal "my-project-key-intake-abcd1234", name
    assert_equal %w[create-bucket put-public-access-block put-bucket-encryption put-bucket-lifecycle-configuration],
                 aws.subcommands
    flat = aws.calls.flatten.join(" ")
    assert_includes flat, "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    assert_includes flat, '"SSEAlgorithm":"AES256"'
    assert_includes flat, '"Expiration":{"Days":1}'
    refute_includes flat, "LocationConstraint", "us-east-1 takes no location constraint"
  end

  def test_other_regions_get_a_location_constraint
    aws = FakeAws.new(region: "eu-west-2")
    bucket(aws).create!
    assert_includes aws.calls.first, "LocationConstraint=eu-west-2"
  end

  def test_name_collision_retries_once_with_new_hex
    aws = FakeAws.new(responses: { "create-bucket" => [ fail_with("BucketAlreadyExists"), ok ] })
    assert_equal "my-project-key-intake-ef567890", bucket(aws).create!
  end

  def test_long_project_names_stay_within_63_chars
    name = bucket(FakeAws.new, project: "x" * 80).create!
    assert_operator name.length, :<=, 63
    assert name.end_with?("-key-intake-abcd1234")
  end

  def test_create_failure_leaves_nothing_to_tear_down
    aws = FakeAws.new(responses: { "create-bucket" => fail_with("AccessDenied") })
    b = bucket(aws)
    assert_raises(SecretIntake::AwsError) { b.create! }
    b.teardown
    assert_equal %w[create-bucket], aws.subcommands
  end

  def test_teardown_deletes_objects_then_bucket_and_is_idempotent
    aws = FakeAws.new
    b = bucket(aws)
    b.create!
    aws.calls.clear
    b.teardown
    b.teardown
    assert_equal [ [ "s3", "rm", "s3://#{b.name}", "--recursive" ], [ "s3api", "delete-bucket", "--bucket", b.name ] ],
                 aws.calls
  end

  def test_teardown_failure_names_the_manual_command
    aws = FakeAws.new(responses: { "delete-bucket" => fail_with("ExpiredToken") })
    b = bucket(aws)
    b.create!
    error = assert_raises(SecretIntake::TeardownError) { b.teardown }
    assert_includes error.message, "aws s3 rb s3://#{b.name} --force --profile personal --region us-east-1"
  end

  def test_arrived_reads_404_as_not_yet_and_other_errors_as_failure
    b = bucket(FakeAws.new(responses: { "head-object" => [ not_found, ok, fail_with("ExpiredToken") ] }))
    b.create!
    refute b.arrived?
    assert b.arrived?
    assert_raises(SecretIntake::AwsError) { b.arrived? }
  end

  def test_page_uploads_from_a_file_not_argv
    aws = FakeAws.new
    b = bucket(aws)
    b.create!
    b.upload_page("<html>SIGNED-PUT-URL</html>")
    put = aws.calls.last
    assert_equal "put-object", put[1]
    refute_includes put.join(" "), "SIGNED-PUT-URL"
    body = put[put.index("--body") + 1]
    refute File.exist?(body), "the page temp file is removed after upload"
  end
end
