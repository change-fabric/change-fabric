import { useState } from "react";
import { authClient, errorMessage } from "../auth";
import { navigate } from "../router";
import { Shell } from "../components/Shell";
import { ErrorNotice } from "../components/Notice";

/**
 * Email and password sign-up. Better Auth is configured to send a verification
 * mail but not to require it before a session exists, so a successful sign-up
 * lands straight on the verification notice with a live session behind it.
 *
 * Its rejections (an address already registered, a password below the minimum)
 * come back as `{ error }` rather than as a throw, and every one of them is
 * rendered inline. Nothing here swallows a failure.
 */
export function SignUp({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const result = await authClient.signUp.email({ name, email, password });
      if (result.error) {
        setError(errorMessage(result.error, "sign-up failed"));
        return;
      }
      // The session exists now, and the account state that decides what renders
      // was loaded before it did. Reload it, or every screen after this one
      // would still be routing as an anonymous visitor.
      navigate("/verify");
      onAuthenticated();
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "sign-up failed");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Shell>
      <div className="auth-panel">
        <p className="eyebrow">change fabric platform</p>
        <h1>Create an account</h1>
        <p className="lede">
          One account, then one organization. Contributor teams hang off the
          organization once it exists.
        </p>

        <form className="form" onSubmit={onSubmit} noValidate>
          <ErrorNotice message={error} />

          <div className="field">
            <label htmlFor="signup-name">Name</label>
            <input
              id="signup-name"
              name="name"
              autoComplete="name"
              required
              value={name}
              onChange={(event) => setName(event.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="signup-email">Email</label>
            <input
              id="signup-email"
              name="email"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="signup-password">Password</label>
            <input
              id="signup-password"
              name="password"
              type="password"
              autoComplete="new-password"
              required
              value={password}
              onChange={(event) => setPassword(event.target.value)}
            />
            <span className="field-hint">At least 8 characters.</span>
          </div>

          <button className="btn" type="submit" disabled={submitting}>
            {submitting ? "Creating account" : "Create account"}
          </button>
        </form>

        <p className="form-footnote">
          Already have an account?{" "}
          <button
            type="button"
            className="nav-link"
            onClick={() => navigate("/login")}
          >
            Log in
          </button>
        </p>
      </div>
    </Shell>
  );
}
