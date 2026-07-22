# The sweep pagination watermark (section 6.4). This holds the DynamoDB
# LastEvaluatedKey (JSON) the scanner writes at the end of each hourly run and
# clears when the pending set drains. It is operational scanner state, not data
# about a person, so it carries NO TTL and is exempt from the 90-day purge
# (section 11).
#
# Terraform owns the parameter's existence but not its value: the Lambda
# overwrites it every run, so ignore_changes on value keeps that runtime write
# from showing up as perpetual drift. We seed "{}" (an empty cursor: start from
# the oldest still-pending item) rather than an empty string, which SSM rejects.
resource "aws_ssm_parameter" "sweep_cursor" {
  name  = local.sweep_cursor_param
  type  = "String"
  value = "{}"

  description = "Secret-scan sweep pagination cursor (DynamoDB LastEvaluatedKey). Written by secret_scanner at runtime."

  lifecycle {
    ignore_changes = [value]
  }
}
