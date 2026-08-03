import { API_ORIGIN } from "./config";

/**
 * The platform's own routes, the ones that are not Better Auth's. Today that is
 * exactly one: turning a fresh sign-up into an organization.
 *
 * Signing up deliberately does not create an organization; `POST /v1/onboarding`
 * does, taking the name and slug a person typed. The slug is never derived from
 * the name, because it is immutable once written and a derived handle would
 * quietly differ from the one they chose.
 */

export interface Organization {
  id: string;
  name: string;
  slug: string;
}

export class OnboardingError extends Error {}

export async function createOrganization(input: {
  organizationName: string;
  organizationSlug: string;
}): Promise<Organization> {
  const response = await fetch(`${API_ORIGIN}/v1/onboarding`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });

  // The route answers JSON on every path it owns, but a gateway or edge error
  // in front of it does not, so a non-JSON body has to become a message rather
  // than a parse crash.
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new OnboardingError(
      `the server answered ${response.status} with no readable body`,
    );
  }

  const payload = body as {
    error?: string;
    organization?: Organization;
  };

  if (!response.ok) {
    throw new OnboardingError(
      payload.error ?? `the server answered ${response.status}`,
    );
  }
  if (payload.organization === undefined) {
    throw new OnboardingError("the server did not return an organization");
  }
  return payload.organization;
}

/** The slug rule the API enforces, mirrored so a typo is caught before a round trip. */
export const SLUG_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
