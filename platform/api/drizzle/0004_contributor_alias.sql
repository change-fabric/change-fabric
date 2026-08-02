CREATE TABLE "contributor_alias" (
	"id" text PRIMARY KEY NOT NULL,
	"team_id" text NOT NULL,
	"legacy_contributor_id" text NOT NULL,
	"display_name" text NOT NULL,
	"user_id" text,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "contributor_alias" ADD CONSTRAINT "contributor_alias_team_id_team_id_fk" FOREIGN KEY ("team_id") REFERENCES "public"."team"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "contributor_alias" ADD CONSTRAINT "contributor_alias_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "contributor_alias_team_id_idx" ON "contributor_alias" USING btree ("team_id");--> statement-breakpoint
CREATE INDEX "contributor_alias_user_id_idx" ON "contributor_alias" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "contributor_alias_team_id_legacy_contributor_id_key" ON "contributor_alias" USING btree ("team_id","legacy_contributor_id");