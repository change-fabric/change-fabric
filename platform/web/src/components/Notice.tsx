import type { ReactNode } from "react";

/**
 * The one place an error reaches a person. Every form routes its server-side
 * rejection through this rather than logging it, so a duplicate email or a weak
 * password is something the page says, not something that silently does nothing.
 *
 * role="alert" so a screen reader announces the failure at the moment it
 * appears, without the reader having to be looking at the form.
 */
export function ErrorNotice({ message }: { message: string | null }) {
  if (message === null) {
    return null;
  }
  return (
    <p className="notice notice-error" role="alert" data-testid="error-notice">
      {message}
    </p>
  );
}

export function InfoNotice({ children }: { children: ReactNode }) {
  return <p className="notice notice-info">{children}</p>;
}
