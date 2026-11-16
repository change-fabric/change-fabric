# frozen_string_literal: true

require_relative "secret_intake_helpers"

class SecretIntakeSsmTest < Minitest::Test
  include SecretIntakeHelpers

  ACCOUNT = "123456789012"
  PARAM = "/app/prod/API_TOKEN"
  Status = Struct.new(:success?)

  # A real AwsRunner over a fake executor: records argv, and for put-parameter
  # also the input json file's path, content and mode at call time.
  class Recorder
    attr_reader :argvs, :inputs

    def initialize(exists:)
      @exists, @argvs, @inputs = exists, [], []
    end

    def call(*argv)
      @argvs << argv
      case argv[1..2]
      when %w[sts get-caller-identity] then [ %({"Account":"#{ACCOUNT}"}), "", Status.new(true) ]
      when %w[iam list-account-aliases] then [ %({"AccountAliases":["prod-alias"]}), "", Status.new(true) ]
      when %w[ssm get-parameter] then get_parameter
      when %w[ssm put-parameter] then put_parameter(argv)
      else [ "", "unexpected", Status.new(false) ]
      end
    end

    def subcommands = @argvs.map { |argv| argv[2] }

    private

    def get_parameter
      return [ %({"Parameter":{"Name":"#{PARAM}"}}), "", Status.new(true) ] if @exists

      [ "", "An error occurred (ParameterNotFound) when calling the GetParameter operation", Status.new(false) ]
    end

    def put_parameter(argv)
      path = argv[argv.index("--cli-input-json") + 1].delete_prefix("file://")
      @inputs << { path: path, json: JSON.parse(File.read(path)), mode: File.stat(path).mode & 0o777 }
      [ %({"Version":2}), "", Status.new(true) ]
    end
  end

  def ssm(recorder)
    @said = []
    aws = SecretIntake::AwsRunner.new(profile: "personal", region: "us-east-1", executor: recorder)
    SecretIntake::Destinations::Ssm.new(aws: aws, say: ->(line) { @said << line })
  end

  def push(recorder, confirm: ACCOUNT, overwrite: false)
    ssm(recorder).push("API_TOKEN", SENTINEL, param: PARAM, confirm_account: confirm, overwrite: overwrite)
  end

  def test_creates_a_secure_string_with_the_value_only_in_the_input_file
    recorder = Recorder.new(exists: false)
    lines = push(recorder)
    assert_equal %w[get-caller-identity list-account-aliases get-parameter put-parameter], recorder.subcommands
    input = recorder.inputs.first
    assert_equal({ "Name" => PARAM, "Value" => SENTINEL, "Type" => "SecureString", "Overwrite" => false }, input[:json])
    assert_equal 0o600, input[:mode]
    refute File.exist?(input[:path])
    recorder.argvs.flatten.each { |arg| refute_includes arg, SENTINEL }
    refute_includes recorder.argvs.flatten, "--with-decryption"
    assert_includes @said.first, "account #{ACCOUNT} (prod-alias)"
    assert_includes @said.first, PARAM
    assert_match(/created #{PARAM}/, lines.first)
  end

  def test_an_existing_parameter_is_refused_without_overwrite
    recorder = Recorder.new(exists: true)
    error = assert_raises(SecretIntake::Destinations::Refused) { push(recorder) }
    assert_includes error.message, "--overwrite"
    refute_includes recorder.subcommands, "put-parameter"
  end

  def test_overwrite_writes_a_new_version
    recorder = Recorder.new(exists: true)
    lines = push(recorder, overwrite: true)
    assert_equal true, recorder.inputs.first[:json]["Overwrite"]
    assert_match(/new version/, lines.first)
  end

  def test_missing_or_mismatched_account_refuses_before_any_write
    [ nil, "999999999999", "12345" ].each do |confirm|
      recorder = Recorder.new(exists: false)
      assert_raises(SecretIntake::Destinations::Refused) { push(recorder, confirm: confirm) }
      assert_equal %w[get-caller-identity list-account-aliases], recorder.subcommands
    end
  end

  def test_cli_maps_refusal_to_exit_6_and_never_prints_the_value
    with_temp_home do |home|
      recorder = Recorder.new(exists: true)
      @out, @err = StringIO.new, StringIO.new
      project = File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
      SecretIntake::StagingStore.new(project: CfProjectIdentity.for(project)).put("API_TOKEN", SENTINEL, validated_by: "none")
      cli = SecretIntake::CLI.new(stdout: @out, stderr: @err, cwd: project, traps: false,
                                  aws_factory: ->(p, r) { SecretIntake::AwsRunner.new(profile: p, region: r, executor: recorder) })
      code = cli.run([ "push", "API_TOKEN", "--to", "ssm:#{PARAM}", "--confirm-account", ACCOUNT ])
      assert_equal 6, code
      assert_includes @out.string, "account #{ACCOUNT}"
      refute_includes @out.string + @err.string, SENTINEL
      assert_equal [], SecretIntake::StagingStore.new(project: CfProjectIdentity.for(project)).list.first[1]["pushes"]
    end
  end
end
