import { useEffect, useState } from "react";
import { createInvitation, listTeams, type Team } from "../api";
import { ErrorNotice } from "./Notice";

/**
 * Inviting somebody into the organization, optionally straight onto a team.
 *
 * The team choice is on this form rather than left as a second step because
 * placing somebody on their team is the common case, and doing it here means the
 * team membership is created in the same transaction as the organization
 * membership when they accept. Leaving it out is still a legitimate answer, so
 * the field defaults to none.
 *
 * The invited person is always a `member`. Handing out an elevated role is a
 * decision that deserves its own deliberate surface, not a dropdown on the
 * fastest path through the product.
 */
export function InviteDialog({ onInvited }: { onInvited: () => void }) {
  const [open, setOpen] = useState(false);
  const [teams, setTeams] = useState<Team[]>([]);
  const [email, setEmail] = useState("");
  const [teamId, setTeamId] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) {
      return;
    }
    let current = true;
    listTeams()
      .then((rows) => {
        if (current) {
          setTeams(rows.filter((team) => team.archivedAt === null));
        }
      })
      .catch(() => {
        // A failed team load is not a failed invite: the team field is optional,
        // so the form stays usable without it rather than refusing to open.
      });
    return () => {
      current = false;
    };
  }, [open]);

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setSent(null);
    setSubmitting(true);
    try {
      const invitation = await createInvitation({ email, teamId });
      setSent(invitation.email);
      setEmail("");
      setTeamId("");
      onInvited();
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not invite");
    } finally {
      setSubmitting(false);
    }
  }

  if (!open) {
    return (
      <button
        type="button"
        className="btn"
        data-testid="open-invite"
        onClick={() => setOpen(true)}
      >
        Invite somebody
      </button>
    );
  }

  return (
    <div className="card invite-card" data-testid="invite-dialog">
      <h2 style={{ marginTop: 0 }}>Invite somebody</h2>

      <form className="form" onSubmit={onSubmit} noValidate>
        <ErrorNotice message={error} />
        {sent === null ? null : (
          <p className="notice notice-info" data-testid="invite-sent">
            Invitation sent to {sent}.
          </p>
        )}

        <div className="field">
          <label htmlFor="invite-email">Email</label>
          <input
            id="invite-email"
            type="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
          />
        </div>

        <div className="field">
          <label htmlFor="invite-team">Team (optional)</label>
          <select
            id="invite-team"
            className="org-switcher"
            value={teamId}
            onChange={(event) => setTeamId(event.target.value)}
          >
            <option value="">No team</option>
            {teams.map((team) => (
              <option key={team.id} value={team.id}>
                {team.name}
              </option>
            ))}
          </select>
          <span className="field-hint">
            They join this team when they accept. More teams can be added later.
          </span>
        </div>

        <div className="key-actions">
          <button
            className="btn"
            type="submit"
            data-testid="send-invite"
            disabled={submitting || email === ""}
          >
            {submitting ? "Sending invitation" : "Send invitation"}
          </button>
          <button
            type="button"
            className="nav-link"
            onClick={() => setOpen(false)}
          >
            Close
          </button>
        </div>
      </form>
    </div>
  );
}
