# frozen_string_literal: true

require_relative "secret_intake_helpers"

class SecretIntakeEnvFileTest < Minitest::Test
  include SecretIntakeHelpers

  def env_in(dir, text = nil, mode: 0o644)
    path = File.join(dir, ".env.local")
    if text
      File.write(path, text)
      File.chmod(mode, path)
    end
    path
  end

  def push(path, value = SENTINEL)
    SecretIntake::Destinations::EnvFile.new(path: path).push("API_TOKEN", value)
  end

  def test_replaces_an_existing_key_and_keeps_the_mode_and_a_backup
    Dir.mktmpdir do |dir|
      path = env_in(dir, "A=1\nAPI_TOKEN=old\nAPI_TOKEN=second\nB=2\n")
      lines = push(path)
      assert_equal "A=1\nAPI_TOKEN=#{SENTINEL}\nAPI_TOKEN=second\nB=2\n", File.read(path)
      assert_equal 0o644, File.stat(path).mode & 0o777
      assert_equal "A=1\nAPI_TOKEN=old\nAPI_TOKEN=second\nB=2\n", File.read("#{path}.bak")
      assert_equal 0o600, File.stat("#{path}.bak").mode & 0o777
      lines.each { |line| refute_includes line, SENTINEL }
    end
  end

  def test_keeps_an_export_prefix
    Dir.mktmpdir do |dir|
      path = env_in(dir, "export API_TOKEN=old\n")
      push(path)
      assert_equal "export API_TOKEN=#{SENTINEL}\n", File.read(path)
    end
  end

  def test_appends_a_missing_key_even_without_a_trailing_newline
    Dir.mktmpdir do |dir|
      path = env_in(dir, "A=1")
      push(path)
      assert_equal "A=1\nAPI_TOKEN=#{SENTINEL}\n", File.read(path)
    end
  end

  def test_a_crlf_file_stays_crlf
    Dir.mktmpdir do |dir|
      path = env_in(dir, "A=1\r\nAPI_TOKEN=old\r\n")
      push(path)
      assert_equal "A=1\r\nAPI_TOKEN=#{SENTINEL}\r\n", File.binread(path)
      path2 = File.join(dir, ".env.other").tap { |p| File.binwrite(p, "A=1\r\n") }
      push(path2)
      assert_equal "A=1\r\nAPI_TOKEN=#{SENTINEL}\r\n", File.binread(path2)
    end
  end

  def test_a_new_file_is_0600_and_has_no_backup
    Dir.mktmpdir do |dir|
      path = env_in(dir)
      lines = push(path)
      assert_equal "API_TOKEN=#{SENTINEL}\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      refute File.exist?("#{path}.bak")
      assert_equal [ "set API_TOKEN in #{path}" ], lines
    end
  end

  def test_quotes_values_a_dotenv_loader_would_split
    assert_equal %(K="a b \\"c\\" \\$d\\nline2"), SecretIntake::Destinations::EnvFile.set("", "K", "a b \"c\" $d\nline2").chomp
  end

  def test_an_unwritable_directory_fails_without_a_partial_write
    Dir.mktmpdir do |dir|
      path = env_in(dir, "API_TOKEN=old\n")
      File.chmod(0o500, dir)
      error = assert_raises(SecretIntake::Destinations::WriteFailed) { push(path) }
      refute_includes error.message, SENTINEL
      assert_equal "API_TOKEN=old\n", File.read(path)
    ensure
      File.chmod(0o700, dir)
    end
  end

  def test_cli_push_never_prints_the_value_and_records_the_push
    with_temp_home do |home|
      cli = cli_for(FakeAws.new, home: home)
      project = File.join(home, "project")
      SecretIntake::StagingStore.new(project: CfProjectIdentity.for(project)).put("API_TOKEN", SENTINEL, validated_by: "none")
      assert_equal 0, cli.run(%w[push API_TOKEN --to env:.env.local])
      assert_equal "API_TOKEN=#{SENTINEL}\n", File.read(File.join(project, ".env.local"))
      assert_includes @out.string, "set API_TOKEN in"
      refute_includes @out.string + @err.string, SENTINEL
    end
  end
end
