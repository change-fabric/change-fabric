# ---------------------------------------------------------------------------
# Postgres-level objects inside the shared instance: one database per
# environment, and one least-privilege login role scoped to it. Phase 8 reuses
# this file verbatim, adding a production pair alongside the staging pair,
# without touching any AWS resource this root already manages.
#
# These resources are gated on var.manage_postgres_objects (default false). The
# postgresql provider speaks Postgres over TCP 5432 from wherever Terraform
# runs, and the instance is deliberately unreachable from outside the VPC: no
# internet gateway, no NAT, publicly_accessible = false. An ordinary apply from a
# laptop therefore creates every AWS resource and leaves these alone; a bootstrap
# run stands up the bastion in bastion.tf, opens an SSM port-forward, and points
# the provider at the local end of it. README.md has the procedure.
# ---------------------------------------------------------------------------

provider "postgresql" {
  # Empty host means talk to the instance directly, which is what a run from
  # inside the VPC does. A bootstrap run through an SSM port-forward overrides
  # both of these to the local end of the tunnel.
  host = var.postgresql_host != "" ? var.postgresql_host : aws_db_instance.platform.address
  port = var.postgresql_port != 0 ? var.postgresql_port : aws_db_instance.platform.port

  username = aws_db_instance.platform.username
  password = random_password.db_master.result

  # RDS terminates TLS on the instance, so the connection is encrypted even when
  # it arrives through a local port-forward. Verification stays off because the
  # tunnel's local hostname can never match the instance's certificate.
  sslmode = "require"

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

  lifecycle {
    # Dropping this database destroys every account, organization and team on
    # staging. Terraform should refuse rather than carry out a plan that says so,
    # whether that plan came from flipping manage_postgres_objects or from an
    # unreachable provider making the resource look absent.
    prevent_destroy = true
  }
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

# Postgres grants PUBLIC connect on the maintenance database, so without this
# every application role could open a session on `postgres` as well as on its
# own database. Nothing legitimate needs that: the master user owns the database
# and keeps its access through the owner ACL, and rdsadmin is a superuser that
# bypasses the check. Revoking it is what makes "scoped to one database" true
# rather than merely intended, and it applies to the production role phase 8
# adds without that phase having to remember.
resource "postgresql_grant" "revoke_public_connect_maintenance" {
  count = var.manage_postgres_objects ? 1 : 0

  database    = "postgres"
  role        = "public"
  object_type = "database"
  privileges  = []
}
