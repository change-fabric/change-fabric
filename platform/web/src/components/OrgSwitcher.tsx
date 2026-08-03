import { useState } from "react";
import { authClient } from "../auth";

export interface OrgSummary {
  id: string;
  name: string;
  slug: string;
}

/**
 * Shows which organization the session is acting as, and lets a person change it
 * only when there is something to change to.
 *
 * A single-organization account gets the name as plain text. A select with one
 * option is a control that cannot do anything, which is worse than no control at
 * all: it invites a click and answers with nothing.
 */
export function OrgSwitcher({
  organizations,
  activeId,
  onSwitched,
}: {
  organizations: OrgSummary[];
  activeId: string | null;
  onSwitched: () => void;
}) {
  const [switching, setSwitching] = useState(false);
  const active = organizations.find((org) => org.id === activeId) ?? null;

  if (organizations.length <= 1) {
    return (
      <div className="org-bar">
        <span className="org-label">Organization</span>
        <span className="org-name" data-testid="active-org-name">
          {active?.name ?? organizations[0]?.name ?? "none"}
        </span>
      </div>
    );
  }

  async function onChange(event: React.ChangeEvent<HTMLSelectElement>) {
    setSwitching(true);
    try {
      await authClient.organization.setActive({
        organizationId: event.target.value,
      });
      onSwitched();
    } finally {
      setSwitching(false);
    }
  }

  return (
    <div className="org-bar">
      <label className="org-label" htmlFor="org-switcher">
        Organization
      </label>
      <select
        id="org-switcher"
        className="org-switcher"
        data-testid="active-org-name"
        value={activeId ?? ""}
        disabled={switching}
        onChange={onChange}
      >
        {organizations.map((org) => (
          <option key={org.id} value={org.id}>
            {org.name}
          </option>
        ))}
      </select>
    </div>
  );
}
