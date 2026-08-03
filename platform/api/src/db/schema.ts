import {
  boolean,
  index,
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
 * Below those sit the first two tables Better Auth does NOT own: `team_api_key`
 * and `repo_link`. They are the platform's own, reached through the store in
 * src/store.ts rather than through the plugin, and they reference the plugin's
 * tables by foreign key so a deleted organization takes its keys and its repo
 * links with it. `artifact`, `artifact_file` and `contributor_alias` belong to
 * later phases and are still deliberately absent.
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
