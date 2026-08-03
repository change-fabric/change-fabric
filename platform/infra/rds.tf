# ---------------------------------------------------------------------------
# ONE Postgres instance holds every environment, as separate databases within it.
# Staging lives in cf_platform_staging today; phase 8 adds cf_platform_production
# to this same instance. That is a settled cost and operations decision, not a
# starting point: a second instance doubles the baseline spend, the backup
# surface, and the patching work for two workloads that together stay well
# inside one db.t4g.small.
#
# The instance identifier is therefore environment-neutral. Only the things that
# genuinely belong to one environment (the database, the role, DNS names) carry
# a -staging or _staging suffix.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "platform" {
  name        = local.name_prefix
  description = "Private subnets for the shared cf-platform Postgres instance."
  subnet_ids  = [for subnet in aws_subnet.private : subnet.id]

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_db_instance" "platform" {
  identifier = local.db_instance_identifier

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # Sized for both environments from day one. 20 GB is the floor; autoscaling
  # takes it to 100 GB without an operator in the loop.
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.platform.arn

  db_name  = null
  username = "cf_platform_admin"
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.platform.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  port                   = 5432

  multi_az = false

  backup_retention_period = 7
  copy_tags_to_snapshot   = true

  # Two independent guards against losing the one instance that holds every
  # environment: AWS refuses a delete outright, and a delete that somehow got
  # through would still have to leave a final snapshot behind.
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.db_instance_identifier}-final"

  performance_insights_enabled = false

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = merge(local.tags, { Name = local.name_prefix })

  lifecycle {
    # The master password lives in SSM and is rotated there plus a targeted
    # apply, never by a drifting plan. Without this, any regeneration of the
    # random value would silently propose a password change on a live instance.
    ignore_changes = [password]
  }
}
