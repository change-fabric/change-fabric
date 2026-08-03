-- Migrations run as the RDS master user, because the application login role
-- holds no DDL privilege by design. That leaves every table owned by the master
-- user and unreadable to the application until it is granted access, which is
-- what this migration does.
--
-- Phase 1 granted the role CONNECT on the database and nothing more, and
-- Postgres 15 onward no longer grants CREATE on the public schema to PUBLIC, so
-- none of this is implied.
--
-- The role name is the one phase 1 created in platform/infra/postgres.tf. A
-- later environment gets its own role and its own copy of this statement rather
-- than a wildcard.

GRANT USAGE ON SCHEMA public TO cf_platform_staging_app;
--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cf_platform_staging_app;
--> statement-breakpoint
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cf_platform_staging_app;
--> statement-breakpoint
-- Tables a later migration creates inherit the same grants without that
-- migration having to remember. Default privileges apply to objects created by
-- the role that runs this statement, which is the master user, which is the
-- role every migration runs as.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cf_platform_staging_app;
--> statement-breakpoint
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO cf_platform_staging_app;
