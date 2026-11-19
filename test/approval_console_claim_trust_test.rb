# frozen_string_literal: true

require "minitest/autorun"

# The cf-prod-claim trust must equal the default immutable sub GitHub issues to
# a job in the cf-claim environment: ids in the repo segment, no customization.
class ApprovalConsoleClaimTrustTest < Minitest::Test
  INFRA = File.expand_path("../approval_console/infra", __dir__)
  PREFIX = "change-fabric@311455213/change-fabric@1180238677"
  SUB = "repo:#{PREFIX}:environment:cf-claim"

  def claim_tf = File.read(File.join(INFRA, "claim.tf"))

  def test_sub_template_renders_the_immutable_subject
    template = claim_tf[/"(repo:\$\{repo\}:environment:[^"]*)"/, 1]
    refute_nil template
    rendered = template.gsub("${repo}", PREFIX).gsub("${var.claim_environment}", "cf-claim")
    assert_equal SUB, rendered
  end

  def test_sub_is_matched_exactly
    trust = claim_tf[/data "aws_iam_policy_document" "claim_trust".*?^}/m]
    refute_match(/StringLike/, trust)
    assert_equal 2, trust.scan('test     = "StringEquals"').size
  end

  def test_claim_repos_accepts_only_id_pinned_prefixes
    pattern = File.read(File.join(INFRA, "variables.tf"))[/can\(regex\("(\^\[A-Za-z0-9_\.-\]\+@.*?\$)", r\)\)/, 1]
    refute_nil pattern
    regex = Regexp.new(pattern.gsub("\\\\", "\\"))
    assert_match regex, PREFIX
    refute_match regex, "change-fabric/change-fabric"
    refute_match regex, "change-fabric@*/change-fabric@*"
  end
end
