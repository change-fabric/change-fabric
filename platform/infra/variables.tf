variable "aws_profile" {
  description = "AWS CLI profile used for provisioning (the personal account)."
  type        = string
  default     = "personal"
}

variable "domain" {
  description = "Apex domain whose existing Route53 hosted zone (owned by site/infra) is read to add the staging wildcard cert validation records."
  type        = string
  default     = "changefabric.org"
}

variable "db_engine_version" {
  description = "Postgres major.minor for the shared cf-platform instance. Pinned so a routine plan never proposes an in-place engine upgrade. 17.10 is the newest stable 17.x this region offers; 17.5 has been superseded."
  type        = string
  default     = "17.10"
}

variable "db_instance_class" {
  description = "Instance class for the shared cf-platform instance. Sized with headroom for BOTH staging and production databases from day one, not for staging alone."
  type        = string
  default     = "db.t4g.small"
}

# The Postgres-level objects (the cf_platform_staging database and its login
# role) are created by the postgresql provider, which connects to the instance
# over TCP 5432 from wherever Terraform runs. The instance is deliberately
# private, so that connection needs the SSM tunnel described in README.md.
#
# This defaults to TRUE because the objects now exist and are in state. Flipping
# it to false does not "skip" them, it plans to DROP the staging database, so a
# plan without a tunnel must fail loudly rather than quietly propose data loss.
# That is the intended behaviour: it fails closed.
variable "manage_postgres_objects" {
  description = "Manage the Postgres database and login role inside the RDS instance. True by default because they exist; setting it false plans to drop them. Planning or applying requires reachability to the instance on 5432, which means the SSM tunnel in README.md."
  type        = bool
  default     = true
}

# The bastion exists only to give a laptop a path to the private instance long
# enough to run the postgres objects, then it goes away. Default false, so an
# ordinary apply neither creates nor keeps it: standing it up is always an
# explicit -var on a bootstrap run. See README.md for the full procedure.
variable "provision_bastion" {
  description = "Stand up the ephemeral SSM bastion and the three SSM interface endpoints that reach it. Set true only for a bootstrap run that creates Postgres objects, then set it back to false to tear the bastion down."
  type        = bool
  default     = false
}

# When the postgresql provider runs through an SSM port-forward, it connects to
# a local port, not to the RDS hostname. Empty means "talk to the instance
# directly", which is what a run from inside the VPC does.
variable "postgresql_host" {
  description = "Host the postgresql provider connects to. Leave empty to use the RDS endpoint directly; set to localhost when tunnelling through an SSM port-forward."
  type        = string
  default     = ""
}

variable "postgresql_port" {
  description = "Port the postgresql provider connects to. Defaults to the RDS instance port; override when an SSM port-forward binds a different local port."
  type        = number
  default     = 0
}

variable "bastion_instance_type" {
  description = "Instance type for the ephemeral bastion. Nothing runs on it but the SSM agent, so the smallest Graviton type is enough."
  type        = string
  default     = "t4g.nano"
}
