import { createAuthClient } from "better-auth/react";
import { organizationClient } from "better-auth/client/plugins";
import { API_ORIGIN } from "./config";

/**
 * The one Better Auth client for the app. The organization plugin is loaded
 * client-side to match the server's plugin list, which is what gives us
 * `authClient.organization.*` and the organization-aware session hooks.
 *
 * `credentials: "include"` is set even though the deployed app is same-origin
 * with its API: it costs nothing there and it is required the moment
 * VITE_API_ORIGIN points somewhere else, so the session cookie behaves the same
 * either way rather than depending on how the app happens to be served.
 */
export const authClient = createAuthClient({
  baseURL: API_ORIGIN,
  plugins: [organizationClient()],
  fetchOptions: {
    credentials: "include",
  },
});

export const { useSession, useListOrganizations, useActiveOrganization } =
  authClient;

/**
 * Better Auth returns `{ data, error }` rather than throwing, and its error
 * objects carry a human-readable `message` for the cases the sign-up and log-in
 * forms actually hit (duplicate email, password too short, bad credentials).
 * This normalises the shape so a form never renders "undefined" and never fails
 * silently: an error with no message still produces something a person can act
 * on.
 */
export function errorMessage(
  error: { message?: string; statusText?: string; status?: number } | null,
  fallback: string,
): string {
  if (error === null) {
    return fallback;
  }
  const text = error.message ?? error.statusText;
  if (typeof text === "string" && text.trim() !== "") {
    return text;
  }
  return fallback;
}
