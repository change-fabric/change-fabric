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
# private: no internet gateway, no NAT, publicly_accessible = false. A laptop
# outside the VPC therefore CANNOT reach it, so these resources are opt-in and
# default OFF. Set this true only when running Terraform from inside the VPC
# (or through a tunnel that terminates inside it); see README.md.
variable "manage_postgres_objects" {
  description = "Create the Postgres database and login role inside the RDS instance. Requires network reachability to the instance on 5432 from wherever Terraform runs. Default false so the AWS-side apply succeeds from anywhere."
  type        = bool
  default     = false
}
