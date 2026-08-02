import { useState } from "react";
import { createOrganization, SLUG_PATTERN } from "../api";
import { authClient } from "../auth";
import { navigate } from "../router";
import { Shell } from "../components/Shell";
import { ErrorNotice } from "../components/Notice";

/**
 * Turns a fresh sign-up into an organization.
 *
 * The slug is typed, not derived from the name. It is immutable once written and
 * ends up in URLs and in whatever a downstream repository records, so deriving it
 * would hand someone a permanent handle they never chose. The field defaults to
 * empty for the same reason: a prefilled guess is still a guess someone accepts
 * without reading.
 *
 * The server owns uniqueness. A slug already taken comes back as a 4xx with the
 * plugin's own message, which lands in the same inline error as everything else.
 */
export function Onboarding({ onCreated }: { onCreated: () => void }) {
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const slugMalformed = slug !== "" && !SLUG_PATTERN.test(slug);

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      const organization = await createOrganization({
        organizationName: name,
        organizationSlug: slug,
      });
      // Onboarding creates the org through the plugin's own path, which sets it
      // active on the session; setActive here makes that explicit so the
      // dashboard does not depend on that side effect staying true.
      await authClient.organization.setActive({
        organizationId: organization.id,
      });
      onCreated();
      navigate("/");
    } catch (cause: unknown) {
      setError(
        cause instanceof Error ? cause.message : "could not create organization",
      );
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Shell>
      <div className="auth-panel">
        <p className="eyebrow">step 3 of 3</p>
        <h1>Name your organization</h1>
        <p className="lede">
          Everything else in the platform belongs to an organization: members,
          contributor teams, and the artifacts a run publishes.
        </p>

        <form className="form" onSubmit={onSubmit} noValidate>
          <ErrorNotice message={error} />

          <div className="field">
            <label htmlFor="org-name">Organization name</label>
            <input
              id="org-name"
              name="organizationName"
              required
              value={name}
              onChange={(event) => setName(event.target.value)}
            />
          </div>

          <div className="field">
            <label htmlFor="org-slug">Slug</label>
            <input
              id="org-slug"
              name="organizationSlug"
              required
              value={slug}
              aria-invalid={slugMalformed || undefined}
              onChange={(event) => setSlug(event.target.value)}
            />
            {slugMalformed ? (
              <span className="field-error">
                Lower-case letters, digits, and internal hyphens only.
              </span>
            ) : (
              <span className="field-hint">
                Permanent. Lower-case letters, digits, and internal hyphens. It
                cannot be changed later.
              </span>
            )}
          </div>

          <button
            className="btn"
            type="submit"
            disabled={submitting || slugMalformed}
          >
            {submitting ? "Creating organization" : "Create organization"}
          </button>
        </form>
      </div>
    </Shell>
  );
}
