# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_env"

# A host-run step sees the minimal base, the run's own CF_CHANGE_* values and
# exactly the names it declares; nothing else from the shell.
class ChangeEnvTest < Minitest::Test
  SOURCE = { "PATH" => "/usr/bin", "HOME" => "/home/x", "SECRET" => "do-not-leak", "TOKEN" => "from-env" }.freeze

  def test_passes_only_base_extra_and_declared_names
    resolved = ChangeEnv.build(declared: %w[TOKEN], extra: { "CF_CHANGE_RUN_ID" => "r1" }, source: SOURCE)
    assert_equal({ "PATH" => "/usr/bin", "HOME" => "/home/x", "CF_CHANGE_RUN_ID" => "r1", "TOKEN" => "from-env" },
                 resolved.env)
    refute resolved.env.key?("SECRET")
  end

  def test_env_wins_over_env_file
    resolved = ChangeEnv.build(declared: %w[TOKEN DB], env_file_values: { "TOKEN" => "from-file", "DB" => "file-db" },
                               source: SOURCE)
    assert_equal "from-env", resolved.env["TOKEN"]
    assert_equal "file-db", resolved.env["DB"]
  end

  def test_undeclared_env_file_keys_are_not_exported
    resolved = ChangeEnv.build(declared: [], env_file_values: { "OTHER" => "x" }, source: SOURCE)
    refute resolved.env.key?("OTHER")
  end

  def test_missing_names_are_listed_together
    error = assert_raises(ChangeEnv::MissingVariables) do
      ChangeEnv.build(declared: %w[A TOKEN B], env_file_values: { "B" => "" }, source: SOURCE)
    end
    assert_equal %w[A B], error.names
    assert_match(/A, B/, error.message)
  end

  def test_masks_longest_value_first
    mask = ChangeEnv.masker("SHORT" => "abcd", "LONG" => "abcdefgh")
    assert_equal "x ***LONG*** y ***SHORT***", mask.call("x abcdefgh y abcd")
  end

  def test_masks_a_non_ascii_value_in_raw_captured_bytes
    raw = "token=sëcret\xFF\n".b
    assert_equal "token=***TOKEN***�\n", ChangeEnv.masker("TOKEN" => "sëcret").call(raw)
  end

  def test_skips_values_shorter_than_four_characters
    mask = ChangeEnv.masker("FLAG" => "on", "KEY" => "s3cret")
    assert_equal "on ***KEY***", mask.call("on s3cret")
  end

  def test_resolved_masker_hides_declared_values_only
    resolved = ChangeEnv.build(declared: %w[TOKEN], source: SOURCE)
    assert_equal "/home/x ***TOKEN***", resolved.masker.call("/home/x from-env")
  end
end
