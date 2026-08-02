import { useEffect, useState } from "react";
import { acceptInvitation, getInvitation, type Invitation } from "../api";
import { navigate } from "../router";
import { Shell } from "../components/Shell";
import { ErrorNotice } from "../components/Notice";

/**
 * Where an invitation link lands.
 *
 * Accepting is an explicit button rather than something the page does on load.
 * A link in an email is followed by mail scanners, link previewers and stray
 * clicks, and joining an organization is not something any of those should be
 * able to do on somebody's behalf.
 *
 * The invitation id comes from the query string, which is the only piece of
 * routing state this app reads from anywhere but the path.
 */
export function invitationIdFromSearch(search: string): string | null {
  const value = new URLSearchParams(search).get("invitation");
  return value === null || value === "" ? null : value;
}

export function AcceptInvite({
  email,
  onAccepted,
}: {
  email: string;
  onAccepted: () => void;
}) {
  const invitationId = invitationIdFromSearch(window.location.search);
  const [invitation, setInvitation] = useState<Invitation | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [accepting, setAccepting] = useState(false);
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (invitationId === null) {
      setError("this link is missing its invitation");
      return;
    }
    let current = true;
    getInvitation(invitationId)
      .then((row) => {
        if (current) {
          setInvitation(row);
        }
      })
      .catch((cause: unknown) => {
        if (current) {
          setError(
            cause instanceof Error
              ? cause.message
              : "this invitation could not be read",
          );
        }
      });
    return () => {
      current = false;
    };
  }, [invitationId]);

  async function onAccept() {
    if (invitationId === null) {
      return;
    }
    setError(null);
    setAccepting(true);
    try {
      await acceptInvitation(invitationId);
      setDone(true);
      onAccepted();
    } catch (cause: unknown) {
      setError(
        cause instanceof Error ? cause.message : "could not accept invitation",
      );
    } finally {
      setAccepting(false);
    }
  }

  return (
    <Shell>
      <div className="auth-panel">
        <p className="eyebrow">invitation</p>
        <h1>Join an organization</h1>

        <ErrorNotice message={error} />

        {done ? (
          <>
            <p className="notice notice-info" data-testid="invite-accepted">
              You have joined the organization.
            </p>
            <button
              className="btn"
              type="button"
              data-testid="go-to-dashboard"
              onClick={() => navigate("/")}
            >
              Go to the dashboard
            </button>
          </>
        ) : invitation === null ? (
          error === null ? (
            <p className="muted">Loading the invitation.</p>
          ) : null
        ) : (
          <>
            <p className="lede">
              You are signed in as {email}. This invitation was sent to{" "}
              <strong data-testid="invitation-email">{invitation.email}</strong>.
            </p>
            <button
              className="btn"
              type="button"
              data-testid="accept-invite"
              disabled={accepting}
              onClick={onAccept}
            >
              {accepting ? "Accepting" : "Accept invitation"}
            </button>
          </>
        )}
      </div>
    </Shell>
  );
}
