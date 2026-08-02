CREATE TABLE "artifact" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"team_id" text NOT NULL,
	"short_id" text NOT NULL,
	"repo_id" text,
	"contributor_user_id" text,
	"contributor_label" text,
	"project" text,
	"branch" text,
	"head_sha" text,
	"pr_number" integer,
	"pr_url" text,
	"status" text NOT NULL,
	"fail_count" integer DEFAULT 0 NOT NULL,
	"warn_count" integer DEFAULT 0 NOT NULL,
	"byte_size" bigint DEFAULT 0 NOT NULL,
	"key_prefix" text NOT NULL,
	"generated_at" timestamp DEFAULT now() NOT NULL,
	"published_at" timestamp,
	"expires_at" timestamp,
	"completion_note" text
);
--> statement-breakpoint
CREATE TABLE "artifact_file" (
	"id" text PRIMARY KEY NOT NULL,
	"artifact_id" text NOT NULL,
	"path" text NOT NULL,
	"content_type" text NOT NULL,
	"bytes" bigint NOT NULL,
	"sha256" text
);
--> statement-breakpoint
ALTER TABLE "artifact" ADD CONSTRAINT "artifact_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "artifact" ADD CONSTRAINT "artifact_team_id_team_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."team"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "artifact" ADD CONSTRAINT "artifact_contributor_user_id_user_id_fk" FOREIGN KEY ("contributor_user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "artifact_file" ADD CONSTRAINT "artifact_file_artifact_id_artifact_id_fk" FOREIGN KEY ("artifact_id") REFERENCES "public"."artifact"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "artifact_team_id_idx" ON "artifact" USING btree ("team_id");--> statement-breakpoint
CREATE INDEX "artifact_organization_id_idx" ON "artifact" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "artifact_team_id_id_idx" ON "artifact" USING btree ("team_id","id");--> statement-breakpoint
CREATE UNIQUE INDEX "artifact_team_id_short_id_key" ON "artifact" USING btree ("team_id","short_id");--> statement-breakpoint
CREATE INDEX "artifact_file_artifact_id_idx" ON "artifact_file" USING btree ("artifact_id");--> statement-breakpoint
CREATE UNIQUE INDEX "artifact_file_artifact_id_path_key" ON "artifact_file" USING btree ("artifact_id","path");