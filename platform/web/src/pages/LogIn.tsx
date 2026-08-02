import { useState } from "react";
import { authClient, errorMessage } from "../auth";
import { navigate } from "../router";
import { Shell } from "../components/Shell";
import { ErrorNotice } from "../components/Notice";

/**
 * Email and password log-in. A wrong credential comes back as an error object,
 * not a throw, so the only way it reaches a person is by being rendered.
 *
 * There is no redirect target to remember: once the session exists, App routes
 * on whether the account has an organization yet.
 */
export function LogIn({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const result = await authClient.signIn.email({ email, password });
      if (result.error) {
        setError(errorMessage(result.error, "could not log in"));
        return;
      }
      // The session exists now, and the account state that decides what renders
      // was loaded before it did. Reload it, or this would route straight back
      // to the log-in form it just came from.
      navigate("/");
      onAuthenticated();
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not log in");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Shell>
      <div className="auth-panel">
        <p className="eyebrow">change fabric platform</p>
        <h1>Log in</h1>

        <form className="form" onSubmit={onSubmit} noValidate>
          <ErrorNotice message={error} />

          <div className="field">
            <label htmlFor="login-email">Email</label>
            <input
              id="login-email"
              name="email"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="login-password">Password</label>
            <input
              id="login-password"
              name="password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
          </div>

          <button className="btn" type="submit" disabled={submitting}>
            {submitting ? "Logging in" : "Log in"}
          </button>
        </form>

        <p className="form-footnote">
          No account yet?{" "}
          <button
            type="button"
            className="nav-link"
            onClick={() => navigate("/signup")}
          >
            Create one
          </button>
        </p>
      </div>
    </Shell>
  );
}
