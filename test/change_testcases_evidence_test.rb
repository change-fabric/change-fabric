# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "base64"
require_relative "../scripts/change_testcases_evidence"

class ChangeTestcasesEvidenceTest < Minitest::Test
  Item = Struct.new(:suite, :id)

  # On a Linux bind mount the browser's checkpoints belong to the container
  # user, so the host cannot open them for writing; a read-only file plays that
  # part. Host writes replace such a file through the shared dir instead.
  def test_host_writes_replace_a_checkpoint_the_host_cannot_open
    Dir.mktmpdir do |out|
      evidence = ChangeTestcasesEvidence.new(ChangeTestcasesEvidence.prepare(out, "run-1"))
      attempt = evidence.open_attempt(Item.new("checkout", "happy"), 1, { "case" => "checkout/happy" })
      shot = File.join(attempt.host_dir, "shot-0001-home.png")
      result = File.join(attempt.host_dir, "result.json")
      [ shot, result ].each { |path| File.write(path, "container"); File.chmod(0o444, path) }
      record = { "ok" => true, "steps" => [ { "index" => 0, "name" => "home", "screenshot" => Base64.strict_encode64("png") } ] }

      evidence.close_attempt(attempt, record)

      assert_equal "png", File.binread(shot)
      assert_equal true, JSON.parse(File.read(result))["ok"]
      assert_empty Dir.glob(File.join(attempt.host_dir, ".*.tmp*"))
    end
  end
end
