import { useCallback, useEffect, useState } from "react";
import { authClient } from "./auth";
import { navigate, usePath } from "./router";
import { Shell } from "./components/Shell";
import type { OrgSummary } from "./components/OrgSwitcher";
import { SignUp } from "./pages/SignUp";
import { LogIn } from "./pages/LogIn";
import { VerifyNotice } from "./pages/VerifyNotice";
import { Onboarding } from "./pages/Onboarding";
import { AcceptInvite } from "./pages/AcceptInvite";
import { AuthorizeViewer } from "./pages/AuthorizeViewer";
import { Dashboard, type ActiveOrg } from "./pages/Dashboard";

/**
 * Routing here is the account's state first and the URL second.
 *
 * The URL alone cannot decide what to render: /onboarding means nothing without
 * a session, and a session with no organization has nowhere to go but
 * onboarding. So the account is loaded once, and the path only chooses among the
 * screens that account can legitimately see. That is also what makes a reload or
 * a pasted deep link land somewhere sensible instead of on a broken shell.
 */

interface Account {
  userName: string;
  userEmail: string;
  organizations: OrgSummary[];
  activeOrg: ActiveOrg | null;
  /** The caller's role in the active organization, as the server reports it. */
  role: string | undefined;
}

type Load =
  | { status: "loading" }
  | { status: "anonymous" }
  | { status: "ready"; account: Account };

function useAccount(): { load: Load; refresh: () => void } {
  const [load, setLoad] = useState<Load>({ status: "loading" });
  // A counter rather than a boolean, so two refreshes in a row are two loads.
  const [generation, setGeneration] = useState(0);

  const refresh = useCallback(() => setGeneration((n) => n + 1), []);

  useEffect(() => {
    // Guards against a response from a superseded load overwriting a newer one,
    // which is what a fast log-out followed by a log-in would otherwise do.
    let current = true;

    async function run() {
      const session = await authClient.getSession();
      if (!current) {
        return;
      }
      const user = session.data?.user;
      if (session.error || user === undefined) {
        setLoad({ status: "anonymous" });
        return;
      }

      const list = await authClient.organization.list();
      const organizations: OrgSummary[] = (list.data ?? []).map((org) => ({
        id: org.id,
        name: org.name,
        slug: org.slug,
      }));

      // getFullOrganization with no query resolves the session's active
      // organization, which the plugin sets when one is created. A brand new
      // account has none, and that is the onboarding case rather than an error.
      let activeOrg: ActiveOrg | null = null;
      let role: string | undefined;
      if (organizations.length > 0) {
        const full = await authClient.organization.getFullOrganization();
        const data = full.data;
        if (data) {
          activeOrg = {
            id: data.id,
            name: data.name,
            slug: data.slug,
            members: data.members,
          };
        } else {
          activeOrg = organizations[0];
        }
        // The caller's own membership row, which is where the role comes from.
        // Reading it off the members list rather than from a second request
        // keeps it consistent with the table rendered right next to it.
        role = activeOrg.members?.find(
          (member) => member.userId === user.id,
        )?.role;
      }

      if (!current) {
        return;
      }
      setLoad({
        status: "ready",
        account: {
          userName: user.name || user.email,
          userEmail: user.email,
          organizations,
          activeOrg,
          role,
        },
      });
    }

    run().catch(() => {
      if (current) {
        setLoad({ status: "anonymous" });
      }
    });

    return () => {
      current = false;
    };
  }, [generation]);

  return { load, refresh };
}

/**
 * The paths an account that already has an organization cannot usefully be on.
 * Rendering the sign-up or onboarding form for one of those would offer a
 * submission whose only outcome is a rejection.
 */
const SETTLED_ACCOUNT_DEAD_ENDS = new Set(["/onboarding", "/signup", "/login"]);

export function App() {
  const path = usePath();
  const { load, refresh } = useAccount();

  const settled =
    load.status === "ready" && load.account.organizations.length > 0;
  const deadEnd = settled && SETTLED_ACCOUNT_DEAD_ENDS.has(path);

  // Navigation is a side effect on the history API, so it belongs in an effect
  // rather than in the render that noticed it.
  useEffect(() => {
    if (deadEnd) {
      navigate("/");
    }
  }, [deadEnd]);

  if (load.status === "loading") {
    return (
      <Shell>
        <p className="lede" style={{ marginTop: 48 }}>
          Loading your account.
        </p>
      </Shell>
    );
  }

  if (load.status === "anonymous") {
    return path === "/signup" ? (
      <SignUp onAuthenticated={refresh} />
    ) : (
      <LogIn onAuthenticated={refresh} />
    );
  }

  const { account } = load;

  if (path === "/verify") {
    return <VerifyNotice email={account.userEmail} />;
  }

  // Before the onboarding branch, not after it. Somebody following an invitation
  // link is very often somebody with no organization yet, and that is exactly
  // the case onboarding would otherwise capture: they would be told to create an
  // organization while holding an invitation to join one.
  if (path === "/accept-invite") {
    return (
      <AcceptInvite email={account.userEmail} onAccepted={refresh} />
    );
  }

  // Also before the onboarding branch, and for the same shape of reason: this
  // path is arrived at by being redirected here from another host, so sending
  // somebody to create an organization instead would strand them with no way
  // back to the link they followed.
  if (path === "/artifacts/authorize") {
    return <AuthorizeViewer />;
  }

  if (account.organizations.length === 0) {
    return <Onboarding onCreated={refresh} />;
  }

  return (
    <Dashboard
      userName={account.userName}
      role={account.role}
      organizations={account.organizations}
      activeOrg={account.activeOrg}
      onRefresh={refresh}
    />
  );
}
