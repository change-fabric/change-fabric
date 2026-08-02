# ---------------------------------------------------------------------------
# Postgres-level objects inside the shared instance: one database per
# environment, and one least-privilege login role scoped to it. Phase 8 reuses
# this file verbatim, adding a production pair alongside the staging pair,
# without touching any AWS resource this root already manages.
#
# These resources are gated on var.manage_postgres_objects (default false). The
# postgresql provider speaks Postgres over TCP 5432 from wherever Terraform
# runs, and the instance is deliberately unreachable from outside the VPC: no
# internet gateway, no NAT, publicly_accessible = false. Applying from a laptop
# therefore creates every AWS resource and leaves these two for a run that has a
# path into the VPC. README.md documents both ways to get one.
# ---------------------------------------------------------------------------

provider "postgresql" {
  host     = aws_db_instance.platform.address
  port     = aws_db_instance.platform.port
  username = aws_db_instance.platform.username
  password = random_password.db_master.result
  sslmode  = "require"

  # RDS grants the master user rds_superuser, not true superuser, so the
  # provider must not attempt superuser-only statements.
  superuser = false
}

resource "postgresql_database" "staging" {
  count = var.manage_postgres_objects ? 1 : 0

  name  = local.staging_database
  owner = aws_db_instance.platform.username

  # Template0 plus an explicit collation keeps the database's sort and encoding
  # behaviour pinned rather than inherited from whatever template1 happens to be.
  template   = "template0"
  encoding   = "UTF8"
  lc_collate = "en_US.UTF-8"
  lc_ctype   = "en_US.UTF-8"
}

# The application login role. It can connect and it can work inside the staging
# database, and it holds no cluster-level privilege: no CREATEDB, no CREATEROLE,
# no replication, no superuser. Schema-level grants belong to the migration
# tooling phase 2 introduces, not here.
resource "postgresql_role" "staging_app" {
  count = var.manage_postgres_objects ? 1 : 0

  name     = local.staging_role
  login    = true
  password = random_password.staging_app.result

  superuser       = false
  create_database = false
  create_role     = false
  replication     = false
  inherit         = true
}

# Scope the role to its own database only. CONNECT is granted explicitly here;
# the public CONNECT that Postgres grants by default is revoked so no future
# role reaches this database implicitly.
resource "postgresql_grant" "staging_app_connect" {
  count = var.manage_postgres_objects ? 1 : 0

  database    = postgresql_database.staging[0].name
  role        = postgresql_role.staging_app[0].name
  object_type = "database"
  privileges  = ["CONNECT", "TEMPORARY"]
}

resource "postgresql_grant" "revoke_public_connect" {
  count = var.manage_postgres_objects ? 1 : 0

  database    = postgresql_database.staging[0].name
  role        = "public"
  object_type = "database"
  privileges  = []
}
