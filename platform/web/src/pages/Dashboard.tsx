import { authClient } from "../auth";
import { navigate, usePath } from "../router";
import { NavButton, Shell } from "../components/Shell";
import { OrgSwitcher, type OrgSummary } from "../components/OrgSwitcher";

export interface MemberRow {
  id: string;
  role: string;
  createdAt?: string | Date;
  user?: { name?: string | null; email?: string | null };
}

export interface ActiveOrg extends OrgSummary {
  members?: MemberRow[];
}

/**
 * The authenticated shell and the two screens inside it.
 *
 * Both screens read the same already-loaded organization rather than fetching
 * their own copy, so switching organizations updates them together and there is
 * no window where the header says one thing and the table says another.
 *
 * Members is read-only in this phase. Inviting, removing, and contributor-team
 * management arrive with the surfaces that own them; a disabled button now would
 * only advertise something that does not exist.
 */

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

export function Dashboard({
  userName,
  organizations,
  activeOrg,
  onRefresh,
}: {
  userName: string;
  organizations: OrgSummary[];
  activeOrg: ActiveOrg | null;
  onRefresh: () => void;
}) {
  const path = usePath();
  const members = activeOrg?.members ?? [];

  const nav = (
    <>
      <NavButton to="/" current={path}>
        Dashboard
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

  return (
    <Shell nav={nav}>
      <div style={{ marginTop: 28 }}>
        <OrgSwitcher
          organizations={organizations}
          activeId={activeOrg?.id ?? null}
          onSwitched={onRefresh}
        />
      </div>

      {path === "/members" ? (
        <>
          <h1 style={{ marginTop: 16 }}>Members</h1>
          <p className="lede">
            Everyone in {activeOrg?.name ?? "this organization"}. Read-only for
            now: invites and role changes are not part of this phase.
          </p>
          <MembersTable members={members} />
        </>
      ) : (
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
              <div className="summary-label">Organizations</div>
              <div className="summary-value">{organizations.length}</div>
            </div>
          </div>

          <h2>Members</h2>
          <MembersTable members={members} />
        </>
      )}
    </Shell>
  );
}
