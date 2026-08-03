import { authClient } from "../auth";
import { navigate, usePath } from "../router";
import { NavButton, Shell } from "../components/Shell";
import { OrgSwitcher, type OrgSummary } from "../components/OrgSwitcher";
import { InviteDialog } from "../components/InviteDialog";
import { Teams } from "./Teams";
import { TeamDetail } from "./TeamDetail";
import { TeamArtifacts } from "./TeamArtifacts";

export interface MemberRow {
  id: string;
  role: string;
  userId?: string;
  createdAt?: string | Date;
  user?: { name?: string | null; email?: string | null };
}

export interface ActiveOrg extends OrgSummary {
  members?: MemberRow[];
}

/**
 * The authenticated shell and the screens inside it.
 *
 * Every screen reads the same already-loaded organization rather than fetching
 * its own copy, so switching organizations updates them together and there is no
 * window where the header says one thing and a table says another. The teams
 * screens are the exception and deliberately so: teams, their members and their
 * keys change from this surface, so they load their own data and reload it after
 * a write rather than waiting for the whole account to be refetched.
 *
 * `canManage` is threaded down from the caller's own `member.role`. It decides
 * which controls exist, and nothing more: the API refuses a member either way,
 * and this is only about not offering a button whose one outcome is a refusal.
 */

/** Roles that may change the organization's shape. Mirrors the API's own rule. */
export function canManageOrganization(role: string | undefined): boolean {
  if (role === undefined) {
    return false;
  }
  return role
    .split(",")
    .map((part) => part.trim())
    .some((part) => part === "owner" || part === "admin");
}

function memberName(member: MemberRow): string {
  const name = member.user?.name;
  if (typeof name === "string" && name.trim() !== "") {
    return name;
  }
  return member.user?.email ?? "unknown";
}

function formatJoined(value: string | Date | undefined): string {
  if (value === undefined) {
    return "";
  }
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? "" : date.toISOString().slice(0, 10);
}

function MembersTable({ members }: { members: MemberRow[] }) {
  if (members.length === 0) {
    return <p className="muted">No members yet.</p>;
  }
  return (
    <div className="table-scroll">
      <table className="members-table" data-testid="members-table">
        <thead>
          <tr>
            <th scope="col">Member</th>
            <th scope="col">Email</th>
            <th scope="col">Role</th>
            <th scope="col">Joined</th>
          </tr>
        </thead>
        <tbody>
          {members.map((member) => (
            <tr key={member.id}>
              <td>{memberName(member)}</td>
              <td className="muted">{member.user?.email ?? ""}</td>
              <td>
                <span
                  className={
                    member.role === "owner" ? "role-tag role-owner" : "role-tag"
                  }
                >
                  {member.role}
                </span>
              </td>
              <td className="muted">{formatJoined(member.createdAt)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The team id in `/teams/<id>`, or null for any other path. */
export function teamIdFromPath(path: string): string | null {
  const match = /^\/teams\/([^/]+)$/.exec(path);
  return match?.[1] ?? null;
}

/** The team id in `/teams/<id>/artifacts`, or null for any other path. */
export function artifactsTeamIdFromPath(path: string): string | null {
  const match = /^\/teams\/([^/]+)\/artifacts$/.exec(path);
  return match?.[1] ?? null;
}

export function Dashboard({
  userName,
  role,
  organizations,
  activeOrg,
  onRefresh,
}: {
  userName: string;
  role: string | undefined;
  organizations: OrgSummary[];
  activeOrg: ActiveOrg | null;
  onRefresh: () => void;
}) {
  const path = usePath();
  const members = activeOrg?.members ?? [];
  const canManage = canManageOrganization(role);
  const teamId = teamIdFromPath(path);
  const artifactsTeamId = artifactsTeamIdFromPath(path);

  const nav = (
    <>
      <NavButton to="/" current={path}>
        Dashboard
      </NavButton>
      <NavButton to="/teams" current={path}>
        Teams
      </NavButton>
      <NavButton to="/members" current={path}>
        Members
      </NavButton>
      <button
        type="button"
        className="nav-link"
        onClick={async () => {
          await authClient.signOut();
          onRefresh();
          navigate("/login");
        }}
      >
        Log out
      </button>
    </>
  );

  function body() {
    // Before the team-detail branch, because /teams/<id>/artifacts is a longer
    // match on the same prefix and the detail regex would otherwise never see
    // it while this one never fired.
    if (artifactsTeamId !== null) {
      return <TeamArtifacts teamId={artifactsTeamId} />;
    }

    if (teamId !== null) {
      return (
        <TeamDetail
          teamId={teamId}
          orgMembers={members}
          canManage={canManage}
        />
      );
    }

    if (path === "/teams") {
      return <Teams canManage={canManage} />;
    }

    if (path === "/members") {
      return (
        <>
          <h1 style={{ marginTop: 16 }}>Members</h1>
          <p className="lede">
            Everyone in {activeOrg?.name ?? "this organization"}. Invite somebody
            by address, and place them on a team as they join.
          </p>
          {canManage ? <InviteDialog onInvited={onRefresh} /> : null}
          <MembersTable members={members} />
        </>
      );
    }

    return (
      <>
        <h1 style={{ marginTop: 16 }} data-testid="dashboard-heading">
          {activeOrg?.name ?? "No organization"}
        </h1>
        <p className="lede">Signed in as {userName}.</p>

        <div className="summary-grid">
          <div className="summary">
            <div className="summary-label">Slug</div>
            <div className="summary-value" data-testid="active-org-slug">
              {activeOrg?.slug ?? "none"}
            </div>
          </div>
          <div className="summary">
            <div className="summary-label">Members</div>
            <div className="summary-value">{members.length}</div>
          </div>
          <div className="summary">
            <div className="summary-label">Your role</div>
            <div className="summary-value" data-testid="active-role">
              {role ?? "unknown"}
            </div>
          </div>
        </div>

        <h2>Members</h2>
        <MembersTable members={members} />
      </>
    );
  }

  return (
    <Shell nav={nav}>
      <div style={{ marginTop: 28 }}>
        <OrgSwitcher
          organizations={organizations}
          activeId={activeOrg?.id ?? null}
          onSwitched={onRefresh}
        />
      </div>
      {body()}
    </Shell>
  );
}
