import { Shell } from "../components/Shell";
import { InfoNotice } from "../components/Notice";
import { navigate } from "../router";

/**
 * What a person sees straight after signing up.
 *
 * The session is already live at this point: staging sits behind the shared
 * Basic Auth gate and SES is still in the sandbox, so Better Auth is configured
 * to send the verification mail without requiring it to hold a session. The
 * screen therefore says what happened and offers the next step rather than
 * blocking on an inbox nobody can open.
 */
export function VerifyNotice({ email }: { email: string | null }) {
  return (
    <Shell>
      <div className="auth-panel">
        <p className="eyebrow">step 2 of 3</p>
        <h1>Check your email</h1>

        <InfoNotice>
          A verification link is on its way
          {email === null ? "" : ` to ${email}`}. Staging mail goes through the
          SES sandbox, so delivery outside a verified address is expected not to
          arrive.
        </InfoNotice>

        <p className="lede" style={{ marginTop: 20 }}>
          Verifying is not required to continue on staging. Set up your
          organization now and confirm the address whenever the mail lands.
        </p>

        <button
          className="btn"
          type="button"
          onClick={() => navigate("/onboarding")}
        >
          Set up your organization
        </button>
      </div>
    </Shell>
  );
}
