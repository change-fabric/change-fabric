# frozen_string_literal: true

require "minitest/autorun"

# The repo's OIDC subject template is include_claim_keys [repo, context,
# job_workflow_ref] with immutable subjects. The cf-prod-claim trust must match
# the sub GitHub then issues to any workflow in the cf-claim environment, and
# the in-repo deploy trusts must match the sub their own workflow gets.
class ApprovalConsoleClaimTrustTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  INFRA = File.join(ROOT, "approval_console/infra")
  PREFIX = "change-fabric@311455213/change-fabric@1180238677"
  WORKFLOWS = "change-fabric/change-fabric/.github/workflows"

  def claim_tf = File.read(File.join(INFRA, "claim.tf"))

  # IAM StringLike: * is any run of characters, ? is one character.
  def like?(pattern, value)
    Regexp.new("\\A#{Regexp.escape(pattern).gsub('\*', '.*').gsub('\?', '.')}\\z").match?(value)
  end

  def claim_pattern
    template = claim_tf[/"(repo:\$\{repo\}:environment:[^"]*)"/, 1]
    refute_nil template
    template.gsub("${repo}", PREFIX).gsub("${var.claim_environment}", "cf-claim")
  end

  def test_claim_trust_takes_any_workflow_in_cf_claim_only
    assert_equal "repo:#{PREFIX}:environment:cf-claim:job_workflow_ref:*", claim_pattern
    assert like?(claim_pattern, "repo:#{PREFIX}:environment:cf-claim:job_workflow_ref:#{WORKFLOWS}/cf-prod.yml@refs/heads/main")
    refute like?(claim_pattern, "repo:#{PREFIX}:environment:staging:job_workflow_ref:#{WORKFLOWS}/cf-prod.yml@refs/heads/main")
    refute like?(claim_pattern, "repo:#{PREFIX}:environment:cf-claim")
  end

  def test_claim_trust_wildcards_only_the_sub
    trust = claim_tf[/data "aws_iam_policy_document" "claim_trust".*?^}/m]
    assert_equal 1, trust.scan('test     = "StringLike"').size
    assert_match(/test     = "StringEquals"\s+variable = "token.actions.githubusercontent.com:aud"/, trust)
  end

  def test_claim_repos_and_environment_admit_no_wildcards
    vars = File.read(File.join(INFRA, "variables.tf"))
    pattern = vars[/can\(regex\("(\^\[A-Za-z0-9_\.-\]\+@.*?\$)", r\)\)/, 1]
    refute_nil pattern
    regex = Regexp.new(pattern.gsub("\\\\", "\\"))
    assert_match regex, PREFIX
    refute_match regex, "change-fabric/change-fabric"
    refute_match regex, "change-fabric@*/change-fabric@*"
    assert_includes vars, 'can(regex("^[A-Za-z0-9_.-]+$", var.claim_environment))'
  end

  def test_staging_deploy_trust_pins_its_workflow_on_main
    sub = "repo:#{PREFIX}:ref:refs/heads/main:job_workflow_ref:#{WORKFLOWS}/deploy-app-staging.yml@refs/heads/main"
    trust = File.read(File.join(ROOT, "platform/infra/webapp.tf"))[/data "aws_iam_policy_document" "deploy_app_trust".*?^}/m]
    refute_match(/StringLike/, trust)
    assert_includes trust, "\"#{sub}\""
  end

  def test_prod_deploy_trust_pins_its_workflow_on_app_tags
    sub = "repo:#{PREFIX}:ref:refs/tags/app/v*:job_workflow_ref:#{WORKFLOWS}/deploy-app-prod.yml@refs/tags/app/v*"
    tf = File.read(File.join(ROOT, "platform/infra/webapp_prod.tf"))
    trust = tf[/data "aws_iam_policy_document" "deploy_app_prod_trust".*?^}/m]
    assert_includes trust, "\"#{sub}\""
    assert_match(/test     = "StringEquals"\s+variable = "token.actions.githubusercontent.com:aud"/, trust)
    assert_equal 1, trust.scan('test     = "StringLike"').size
    workflow = File.read(File.join(ROOT, ".github/workflows/deploy-app-prod.yml"))
    refute_match(/^\s+environment:/, workflow)
    assert like?(sub, "repo:#{PREFIX}:ref:refs/tags/app/v1.2.3:job_workflow_ref:#{WORKFLOWS}/deploy-app-prod.yml@refs/tags/app/v1.2.3")
    refute like?(sub, "repo:#{PREFIX}:ref:refs/heads/main:job_workflow_ref:#{WORKFLOWS}/deploy-app-prod.yml@refs/heads/main")
    refute like?(sub, "repo:#{PREFIX}:ref:refs/tags/app/v1.2.3:job_workflow_ref:#{WORKFLOWS}/deploy-app-staging.yml@refs/tags/app/v1.2.3")
  end

  def test_prod_deploy_permissions_stay_on_prod_resources
    perms = File.read(File.join(ROOT, "platform/infra/webapp_prod.tf"))[/data "aws_iam_policy_document" "deploy_app_prod_permissions".*?^}/m]
    assert_equal 2, perms.scan("statement {").size
    assert_includes perms, "aws_s3_bucket.app_prod.arn"
    assert_includes perms, "aws_cloudfront_distribution.app_prod.arn"
    refute_match(/aws_s3_bucket\.app\.|aws_cloudfront_distribution\.app\.|ssm:|kms:/, perms)
  end

  def test_site_deploy_trust_still_matches_a_tag_run
    sub = "repo:#{PREFIX}:ref:refs/tags/site/v1.2.3:job_workflow_ref:#{WORKFLOWS}/deploy-site.yml@refs/tags/site/v1.2.3"
    values = File.read(File.join(ROOT, "site/infra/oidc.tf")).scan(/"(repo:[^"]*)"/).flatten
    assert(values.any? { |pattern| like?(pattern, sub) })
    refute(values.any? { |pattern| like?(pattern, sub.gsub("refs/tags/site/v1.2.3", "refs/heads/main")) })
  end
end
