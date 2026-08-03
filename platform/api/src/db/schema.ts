import {
  bigint,
  boolean,
  index,
  integer,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
} from "drizzle-orm/pg-core";

/**
 * Drizzle mirror of the tables Better Auth owns: its four core models plus the
 * organization plugin's five. The exported binding names (`user`, `teamMember`,
 * ...) are the model names the drizzle adapter looks tables up by, and each
 * column's property name is the Better Auth field name, so those two sides must
 * not drift even though the physical column names are snake_case.
 *
 * Below those sit the tables Better Auth does NOT own: `team_api_key`,
 * `repo_link`, `artifact` and `artifact_file`. They are the platform's own,
 * reached through the store in src/store.ts rather than through the plugin, and
 * they reference the plugin's tables by foreign key so a deleted organization
 * takes its keys, its repo links and its artifacts with it.
 * `contributor_alias` belongs to a later phase and is still deliberately
 * absent.
 */

export const user = pgTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").notNull().default(false),
  image: text("image"),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

export const session = pgTable(
  "session",
  {
    id: text("id").primaryKey(),
    expiresAt: timestamp("expires_at").notNull(),
    token: text("token").notNull().unique(),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    updatedAt: timestamp("updated_at").notNull().defaultNow(),
    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    // Written by the organization plugin when a session switches context.
    activeOrganizationId: text("active_organization_id"),
    activeTeamId: text("active_team_id"),
  },
  (table) => [index("session_user_id_idx").on(table.userId)],
);

export const account = pgTable(
  "account",
  {
    id: text("id").primaryKey(),
    accountId: text("account_id").notNull(),
    providerId: text("provider_id").notNull(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    accessToken: text("access_token"),
    refreshToken: text("refresh_token"),
    idToken: text("id_token"),
    accessTokenExpiresAt: timestamp("access_token_expires_at"),
    refreshTokenExpiresAt: timestamp("refresh_token_expires_at"),
    scope: text("scope"),
    // Better Auth stores the password hash here for the credential provider.
    password: text("password"),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    updatedAt: timestamp("updated_at").notNull().defaultNow(),
  },
  (table) => [index("account_user_id_idx").on(table.userId)],
);

export const verification = pgTable(
  "verification",
  {
    id: text("id").primaryKey(),
    identifier: text("identifier").notNull(),
    value: text("value").notNull(),
    expiresAt: timestamp("expires_at").notNull(),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    updatedAt: timestamp("updated_at").notNull().defaultNow(),
  },
  (table) => [index("verification_identifier_idx").on(table.identifier)],
);

export const organization = pgTable("organization", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  slug: text("slug").notNull().unique(),
  logo: text("logo"),
  metadata: text("metadata"),
  createdAt: timestamp("created_at").notNull().defaultNow(),
});

export const member = pgTable(
  "member",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    role: text("role").notNull().default("member"),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  },
  (table) => [
    index("member_organization_id_idx").on(table.organizationId),
    index("member_user_id_idx").on(table.userId),
  ],
);

export const team = pgTable(
  "team",
  {
    id: text("id").primaryKey(),
    name: text("name").notNull(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    updatedAt: timestamp("updated_at"),
    // Platform additions, declared to Better Auth through
    // schema.team.additionalFields so the plugin reads and writes them too.
    slug: text("slug").notNull(),
    publicKeyEd25519: text("public_key_ed25519"),
    legacyTeamId: text("legacy_team_id").unique(),
    // Archiving is a soft delete, not a row removal. A team's slug appears in
    // artifact paths and in whatever a downstream repository already recorded,
    // and its API keys and repo links point at it, so deleting the row would
    // strand references rather than retire them. Null means active.
    archivedAt: timestamp("archived_at"),
  },
  (table) => [
    index("team_organization_id_idx").on(table.organizationId),
    // A team slug is unique within its organization, not globally: two
    // organizations may each have a `core` team, and neither should block the
    // other. This is the constraint the application's immutability rule leans
    // on, so it lives in the database rather than only in a handler.
    uniqueIndex("team_organization_id_slug_key").on(
      table.organizationId,
      table.slug,
    ),
  ],
);

export const teamMember = pgTable(
  "team_member",
  {
    id: text("id").primaryKey(),
    teamId: text("team_id")
      .notNull()
      .references(() => team.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at").defaultNow(),
  },
  (table) => [
    index("team_member_team_id_idx").on(table.teamId),
    index("team_member_user_id_idx").on(table.userId),
  ],
);

export const invitation = pgTable(
  "invitation",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    email: text("email").notNull(),
    role: text("role"),
    teamId: text("team_id").references(() => team.id, { onDelete: "cascade" }),
    status: text("status").notNull().default("pending"),
    expiresAt: timestamp("expires_at").notNull(),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    inviterId: text("inviter_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
  },
  (table) => [
    index("invitation_organization_id_idx").on(table.organizationId),
    index("invitation_email_idx").on(table.email),
  ],
);

/**
 * A bearer credential a contributor team's tooling presents instead of a
 * session. Phase 6 is the real consumer; this phase mints, lists and revokes
 * them, and proves one resolves.
 *
 * Only the SHA-256 digest of the raw key is stored, so a copy of this table is
 * not a copy of anyone's credentials. `key_prefix` exists because the raw key is
 * shown exactly once and a person still has to be able to tell two of their own
 * keys apart afterwards; it is a strict, non-secret prefix of the raw value.
 *
 * `revoked_at` and `expires_at` are separate: revoking is a decision someone
 * made, expiring is a date passing, and a lookup has to reject both.
 */
export const teamApiKey = pgTable(
  "team_api_key",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    teamId: text("team_id")
      .notNull()
      .references(() => team.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    // Unique, so the digest is what a lookup indexes on and two keys can never
    // collide into one row silently.
    keyHash: text("key_hash").notNull().unique(),
    keyPrefix: text("key_prefix").notNull(),
    createdByUserId: text("created_by_user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    lastUsedAt: timestamp("last_used_at"),
    expiresAt: timestamp("expires_at"),
    revokedAt: timestamp("revoked_at"),
  },
  (table) => [
    index("team_api_key_team_id_idx").on(table.teamId),
    index("team_api_key_organization_id_idx").on(table.organizationId),
  ],
);

/**
 * A git repository claimed by exactly one contributor team.
 *
 * `repo_id` is the normalized `host/path` form of a git remote
 * (`github.com/acme/web`), not a URL: the same repository is reachable over SSH
 * and HTTPS with different spellings, and a claim has to survive both. It is
 * unique across the whole table rather than per organization on purpose, because
 * the question this row answers is "which team owns what a run pushed from", and
 * two organizations both claiming one repository has no consistent answer.
 */
export const repoLink = pgTable(
  "repo_link",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    teamId: text("team_id")
      .notNull()
      .references(() => team.id, { onDelete: "cascade" }),
    repoId: text("repo_id").notNull().unique(),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  },
  (table) => [
    index("repo_link_team_id_idx").on(table.teamId),
    index("repo_link_organization_id_idx").on(table.organizationId),
  ],
);

/**
 * One published run of findings: the manifest a contributor's tooling declared,
 * and the pointer to where its files actually live.
 *
 * The row is the record; S3 is only storage. That split is what makes the rest
 * work. `key_prefix` is written here at creation time as
 * `<org-slug>/<team-slug>/<short-id>/`, and every presigned URL and every
 * CloudFront signed cookie is scoped to it, so authorization is a question about
 * this row rather than a question about a bucket listing. Nothing derives the
 * prefix a second time from parts that could have changed since.
 *
 * `published_at` is null until POST /v1/artifacts/:id/complete says the upload
 * finished. A row with `generated_at` but no `published_at` is a run that was
 * announced and then abandoned, which is a real state worth being able to see
 * rather than one to paper over by writing both at once.
 *
 * `repo_id` is nullable in this phase on purpose. Phase 6 is what actually knows
 * which repository a run came from; recording a value here now would be
 * recording a guess.
 *
 * `contributor_user_id` and `contributor_label` are both nullable and both
 * present because a run may come from a person (a session) or from a machine (a
 * team API key, which belongs to a team and not to anybody). Folding them into
 * one column would mean either losing the foreign key or storing a user id that
 * names nobody.
 */
export const artifact = pgTable(
  "artifact",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    teamId: text("team_id")
      .notNull()
      .references(() => team.id, { onDelete: "cascade" }),
    // Ten Crockford base32 characters. Unique per TEAM rather than globally,
    // matching the team slug rule directly above: a short id only ever appears
    // inside a path that already names the team, so global uniqueness would
    // constrain more than the product needs.
    shortId: text("short_id").notNull(),
    repoId: text("repo_id"),
    contributorUserId: text("contributor_user_id").references(() => user.id, {
      onDelete: "set null",
    }),
    contributorLabel: text("contributor_label"),
    project: text("project"),
    branch: text("branch"),
    headSha: text("head_sha"),
    prNumber: integer("pr_number"),
    prUrl: text("pr_url"),
    // pass, fail or warn. Text rather than an enum because the set of grades is
    // owned by the audit lanes, not by this schema, and a migration per new
    // grade would put this table in the way of a change that has nothing to do
    // with it.
    status: text("status").notNull(),
    failCount: integer("fail_count").notNull().default(0),
    warnCount: integer("warn_count").notNull().default(0),
    // A total in bytes, so it can exceed a 32-bit integer without anybody
    // having to think about it. Read back as a JavaScript number because a
    // findings bundle is megabytes, not petabytes.
    byteSize: bigint("byte_size", { mode: "number" }).notNull().default(0),
    keyPrefix: text("key_prefix").notNull(),
    // When the run itself happened, as the tooling reported it, versus when the
    // upload finished. They are different clocks and different facts.
    generatedAt: timestamp("generated_at").notNull().defaultNow(),
    publishedAt: timestamp("published_at"),
    expiresAt: timestamp("expires_at"),
    // What POST .../complete found when it compared the uploaded objects
    // against what was declared. Null means it agreed. A mismatch is recorded
    // rather than raised, because a run whose bytes are already in the bucket
    // is more useful published with a note than refused outright.
    completionNote: text("completion_note"),
  },
  (table) => [
    index("artifact_team_id_idx").on(table.teamId),
    index("artifact_organization_id_idx").on(table.organizationId),
    // The listing route pages by descending id inside one team, so the index it
    // reads is the compound one rather than either column alone.
    index("artifact_team_id_id_idx").on(table.teamId, table.id),
    uniqueIndex("artifact_team_id_short_id_key").on(
      table.teamId,
      table.shortId,
    ),
  ],
);

/**
 * One file inside an artifact.
 *
 * The rows are written when the artifact is created, from the manifest the
 * caller declared, and not when the bytes arrive: the presigned URL each row
 * corresponds to is handed out in the same response, so a row that never
 * receives its object is exactly the evidence that an upload was incomplete.
 * `path` is relative to the artifact's `key_prefix` and never absolute, so the
 * full S3 key is one concatenation and there is no second spelling of it.
 */
export const artifactFile = pgTable(
  "artifact_file",
  {
    id: text("id").primaryKey(),
    artifactId: text("artifact_id")
      .notNull()
      .references(() => artifact.id, { onDelete: "cascade" }),
    path: text("path").notNull(),
    contentType: text("content_type").notNull(),
    bytes: bigint("bytes", { mode: "number" }).notNull(),
    sha256: text("sha256"),
  },
  (table) => [
    index("artifact_file_artifact_id_idx").on(table.artifactId),
    // One row per path per artifact. Two rows for the same path would be two
    // presigned URLs for one key, and whichever upload finished last would win
    // silently.
    uniqueIndex("artifact_file_artifact_id_path_key").on(
      table.artifactId,
      table.path,
    ),
  ],
);
