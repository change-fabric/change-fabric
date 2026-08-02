CREATE TABLE "repo_link" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"team_id" text NOT NULL,
	"repo_id" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "repo_link_repo_id_unique" UNIQUE("repo_id")
);
--> statement-breakpoint
CREATE TABLE "team_api_key" (
	"id" text PRIMARY KEY NOT NULL,
	"organization_id" text NOT NULL,
	"team_id" text NOT NULL,
	"name" text NOT NULL,
	"key_hash" text NOT NULL,
	"key_prefix" text NOT NULL,
	"created_by_user_id" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"last_used_at" timestamp,
	"expires_at" timestamp,
	"revoked_at" timestamp,
	CONSTRAINT "team_api_key_key_hash_unique" UNIQUE("key_hash")
);
--> statement-breakpoint
ALTER TABLE "team" ADD COLUMN "archived_at" timestamp;--> statement-breakpoint
ALTER TABLE "repo_link" ADD CONSTRAINT "repo_link_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "repo_link" ADD CONSTRAINT "repo_link_team_id_team_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."team"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "team_api_key" ADD CONSTRAINT "team_api_key_organization_id_organization_id_fk" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "team_api_key" ADD CONSTRAINT "team_api_key_team_id_team_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."team"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "team_api_key" ADD CONSTRAINT "team_api_key_created_by_user_id_user_id_fk" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "repo_link_team_id_idx" ON "repo_link" USING btree ("team_id");--> statement-breakpoint
CREATE INDEX "repo_link_organization_id_idx" ON "repo_link" USING btree ("organization_id");--> statement-breakpoint
CREATE INDEX "team_api_key_team_id_idx" ON "team_api_key" USING btree ("team_id");--> statement-breakpoint
CREATE INDEX "team_api_key_organization_id_idx" ON "team_api_key" USING btree ("organization_id");