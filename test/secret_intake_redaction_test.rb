# frozen_string_literal: true

require_relative "secret_intake_helpers"

# End to end on fakes with a sentinel secret: neither the secret nor the signed
# PUT URL reaches stdout, stderr, or any file other than the staged one.
class SecretIntakeRedactionTest < Minitest::Test
  include SecretIntakeHelpers

  # Captures the PUT URL the page was rendered with, so the test knows what
  # must never be printed.
  class SpyRenderer < SecretIntake::PageRenderer
    attr_reader :put_url

    def render(put_url:, **rest)
      @put_url = put_url
      super
    end
  end

  def run_intake(home, aws, validator: FakeValidator.new)
    renderer = SpyRenderer.new
    out, err = StringIO.new, StringIO.new
    project = File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    clock = -> { Time.utc(2030, 1, 1, 12) }
    cli = SecretIntake::CLI.new(stdout: out, stderr: err, cwd: project, aws_factory: ->(_p, _r) { aws },
                                renderer: renderer, validator: validator, clock: clock, traps: false,
                                poller: SecretIntake::Poller.new(clock: clock, sleeper: ->(_) {}))
    code = cli.run(%w[intake --name API_TOKEN --validate openai])
    [ code, out.string, err.string, renderer.put_url ]
  end

  def files_holding(home, needle)
    Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) && File.binread(path).include?(needle) }
  end

  def test_success_prints_neither_secret_nor_put_url
    with_temp_home do |home|
      code, out, err, put_url = run_intake(home, FakeAws.new(responses: { "head-object" => [ not_found, ok ] }))
      assert_equal 0, code
      [ out, err ].each do |stream|
        refute_includes stream, SENTINEL
        refute_includes stream, put_url
        refute_includes stream, put_url[/X-Amz-Signature=(\h+)/, 1]
      end
      assert_equal 1, out.scan("https://").size, "the page link is printed exactly once"
      staged = files_holding(home, SENTINEL)
      assert_equal 1, staged.size
      assert_match %r{/staged/API_TOKEN\z}, staged.first
      assert_empty files_holding(home, put_url)
    end
  end

  # A validator whose failure reason echoes the value it was given, the worst
  # case for a provider error message.
  class EchoingValidator
    def call(_provider, value) = CfKeyValidator::Result.new(false, "rejected #{value}")
  end

  def test_failure_messages_are_scrubbed
    with_temp_home do |home|
      code, out, err, = run_intake(home, FakeAws.new(responses: { "head-object" => ok }), validator: EchoingValidator.new)
      assert_equal 3, code
      refute_includes out + err, SENTINEL
      assert_includes err, "rejected [redacted]"
      assert_empty files_holding(home, SENTINEL)
    end
  end

  def test_aws_argv_never_carries_the_secret_or_put_url
    with_temp_home do |home|
      aws = FakeAws.new(responses: { "head-object" => ok })
      _, _, _, put_url = run_intake(home, aws)
      flat = aws.calls.flatten.join(" ")
      refute_includes flat, SENTINEL
      refute_includes flat, put_url
    end
  end

  def test_redactor_scrubs_longest_first_and_ignores_short_values
    redactor = SecretIntake::Redactor.new.add("abc").add("token-1").add("token-123")
    assert_equal "x [redacted] abc", redactor.scrub("x token-123 abc")
  end
end
