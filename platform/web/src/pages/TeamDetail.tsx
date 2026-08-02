import { useCallback, useEffect, useState } from "react";
import {
  addTeamMember,
  archiveTeam,
  listKeys,
  listTeamMembers,
  listTeams,
  mintKey,
  removeTeamMember,
  renameTeam,
  revokeKey,
  type ApiKey,
  type Team,
  type TeamMember,
} from "../api";
import { navigate } from "../router";
import { ErrorNotice } from "../components/Notice";
import type { MemberRow } from "./Dashboard";

/**
 * One team: what it is called, who is on it, and what keys it has.
 *
 * The key panel is the part with a real constraint behind it. A minted key is
 * shown once, in a banner that says so, and then never again: the API stores
 * only its digest, so there is nothing to show later even if this page wanted
 * to. The banner therefore stays until it is dismissed rather than clearing on
 * the next render, and the listing below it shows prefixes only.
 */

function formatWhen(value: string | null): string {
  if (value === null) {
    return "never";
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "never" : date.toISOString().slice(0, 16).replace("T", " ");
}

function KeysPanel({
  team,
  canManage,
}: {
  team: Team;
  canManage: boolean;
}) {
  const [keys, setKeys] = useState<ApiKey[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [minting, setMinting] = useState(false);
  const [revealed, setRevealed] = useState<{ name: string; key: string } | null>(
    null,
  );
  const [copied, setCopied] = useState(false);
  const [generation, setGeneration] = useState(0);

  useEffect(() => {
    let current = true;
    listKeys(team.id)
      .then((rows) => {
        if (current) {
          setKeys(rows);
        }
      })
      .catch((cause: unknown) => {
        if (current) {
          setError(cause instanceof Error ? cause.message : "could not load keys");
        }
      });
    return () => {
      current = false;
    };
  }, [team.id, generation]);

  async function onMint(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setMinting(true);
    try {
      const result = await mintKey(team.id, name);
      setRevealed({ name: result.apiKey.name, key: result.key });
      setCopied(false);
      setName("");
      setGeneration((n) => n + 1);
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not create key");
    } finally {
      setMinting(false);
    }
  }

  async function onRevoke(keyId: string) {
    setError(null);
    try {
      await revokeKey(team.id, keyId);
      setGeneration((n) => n + 1);
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not revoke key");
    }
  }

  return (
    <>
      <h2>Keys</h2>
      <p className="lede">
        A key authenticates this team's tooling instead of a person. Only the
        digest is stored, so a key can be replaced but never recovered.
      </p>

      <ErrorNotice message={error} />

      {revealed === null ? null : (
        <div className="notice notice-key" data-testid="revealed-key">
          <p className="key-warning">
            Copy this now. It is shown once and cannot be retrieved again.
          </p>
          <code className="key-value" data-testid="revealed-key-value">
            {revealed.key}
          </code>
          <div className="key-actions">
            <button
              type="button"
              className="btn btn-quiet"
              onClick={() => {
                navigator.clipboard
                  ?.writeText(revealed.key)
                  .then(() => setCopied(true))
                  .catch(() => setCopied(false));
              }}
            >
              {copied ? "Copied" : "Copy key"}
            </button>
            <button
              type="button"
              className="nav-link"
              data-testid="dismiss-key"
              onClick={() => setRevealed(null)}
            >
              I have saved it
            </button>
          </div>
        </div>
      )}

      {canManage && team.archivedAt === null ? (
        <form className="form inline-form" onSubmit={onMint} noValidate>
          <div className="field">
            <label htmlFor="key-name">Key name</label>
            <input
              id="key-name"
              required
              value={name}
              placeholder="ci"
              onChange={(event) => setName(event.target.value)}
            />
          </div>
          <button
            className="btn"
            type="submit"
            data-testid="create-key"
            disabled={minting || name === ""}
          >
            {minting ? "Creating key" : "Create key"}
          </button>
        </form>
      ) : null}

      {keys === null ? (
        <p className="muted">Loading keys.</p>
      ) : keys.length === 0 ? (
        <p className="muted">No keys yet.</p>
      ) : (
        <div className="table-scroll">
          <table className="members-table" data-testid="keys-table">
            <thead>
              <tr>
                <th scope="col">Name</th>
                <th scope="col">Prefix</th>
                <th scope="col">Last used</th>
                <th scope="col">Status</th>
                <th scope="col" />
              </tr>
            </thead>
            <tbody>
              {keys.map((key) => (
                <tr key={key.id} data-testid={`key-row-${key.id}`}>
                  <td>{key.name}</td>
                  <td className="muted">
                    <code>{key.keyPrefix}</code>
                  </td>
                  <td className="muted" data-testid={`key-last-used-${key.id}`}>
                    {formatWhen(key.lastUsedAt)}
                  </td>
                  <td>
                    <span
                      className={
                        key.revokedAt === null
                          ? "role-tag"
                          : "role-tag role-archived"
                      }
                      data-testid={`key-status-${key.id}`}
                    >
                      {key.revokedAt === null ? "active" : "revoked"}
                    </span>
                  </td>
                  <td>
                    {canManage && key.revokedAt === null ? (
                      <button
                        type="button"
                        className="nav-link danger-link"
                        data-testid={`revoke-key-${key.id}`}
                        onClick={() => onRevoke(key.id)}
                      >
                        Revoke
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function MembersPanel({
  team,
  orgMembers,
  canManage,
}: {
  team: Team;
  orgMembers: MemberRow[];
  canManage: boolean;
}) {
  const [members, setMembers] = useState<TeamMember[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [picked, setPicked] = useState("");
  const [busy, setBusy] = useState(false);
  const [generation, setGeneration] = useState(0);

  useEffect(() => {
    let current = true;
    listTeamMembers(team.id)
      .then((rows) => {
        if (current) {
          setMembers(rows);
        }
      })
      .catch((cause: unknown) => {
        if (current) {
          setError(
            cause instanceof Error ? cause.message : "could not load members",
          );
        }
      });
    return () => {
      current = false;
    };
  }, [team.id, generation]);

  const onTeam = new Set((members ?? []).map((row) => row.userId));
  // Only somebody already in the organization can be put on a team. That is the
  // API's constraint, and offering a name the server would refuse would be a
  // control that exists to fail.
  const addable = orgMembers.filter(
    (row) => row.userId !== undefined && !onTeam.has(row.userId),
  );

  async function onAdd(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      await addTeamMember(team.id, picked);
      setPicked("");
      setGeneration((n) => n + 1);
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not add member");
    } finally {
      setBusy(false);
    }
  }

  async function onRemove(userId: string) {
    setError(null);
    try {
      await removeTeamMember(team.id, userId);
      setGeneration((n) => n + 1);
    } catch (cause: unknown) {
      setError(
        cause instanceof Error ? cause.message : "could not remove member",
      );
    }
  }

  return (
    <>
      <h2>Members</h2>
      <ErrorNotice message={error} />

      {canManage && team.archivedAt === null ? (
        <form className="form inline-form" onSubmit={onAdd} noValidate>
          <div className="field">
            <label htmlFor="member-picker">Add an organization member</label>
            <select
              id="member-picker"
              className="org-switcher"
              data-testid="member-picker"
              value={picked}
              onChange={(event) => setPicked(event.target.value)}
            >
              <option value="">Choose somebody</option>
              {addable.map((row) => (
                <option key={row.id} value={row.userId}>
                  {row.user?.name || row.user?.email || row.userId}
                </option>
              ))}
            </select>
            <span className="field-hint">
              Only people already in this organization. Invite somebody new from
              the Members page.
            </span>
          </div>
          <button
            className="btn"
            type="submit"
            data-testid="add-team-member"
            disabled={busy || picked === ""}
          >
            {busy ? "Adding" : "Add to team"}
          </button>
        </form>
      ) : null}

      {members === null ? (
        <p className="muted">Loading members.</p>
      ) : members.length === 0 ? (
        <p className="muted">Nobody is on this team yet.</p>
      ) : (
        <div className="table-scroll">
          <table className="members-table" data-testid="team-members-table">
            <thead>
              <tr>
                <th scope="col">Member</th>
                <th scope="col">Email</th>
                <th scope="col" />
              </tr>
            </thead>
            <tbody>
              {members.map((member) => (
                <tr key={member.id} data-testid={`team-member-${member.email}`}>
                  <td>{member.name}</td>
                  <td className="muted">{member.email}</td>
                  <td>
                    {canManage && team.archivedAt === null ? (
                      <button
                        type="button"
                        className="nav-link danger-link"
                        onClick={() => onRemove(member.userId)}
                      >
                        Remove
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

export function TeamDetail({
  teamId,
  orgMembers,
  canManage,
}: {
  teamId: string;
  orgMembers: MemberRow[];
  canManage: boolean;
}) {
  const [team, setTeam] = useState<Team | null>(null);
  const [missing, setMissing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [rename, setRename] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    let current = true;
    listTeams()
      .then((rows) => {
        if (!current) {
          return;
        }
        const found = rows.find((row) => row.id === teamId) ?? null;
        setTeam(found);
        setMissing(found === null);
        setRename(found?.name ?? "");
      })
      .catch((cause: unknown) => {
        if (current) {
          setError(cause instanceof Error ? cause.message : "could not load team");
        }
      });
    return () => {
      current = false;
    };
  }, [teamId]);

  useEffect(load, [load]);

  if (missing) {
    return (
      <>
        <h1 style={{ marginTop: 16 }}>No such team</h1>
        <p className="lede">
          This team does not exist in the organization you are acting as.
        </p>
        <button
          type="button"
          className="btn btn-quiet"
          onClick={() => navigate("/teams")}
        >
          Back to teams
        </button>
      </>
    );
  }

  if (team === null) {
    return <p className="muted">Loading team.</p>;
  }

  async function onRename(event: React.FormEvent) {
    event.preventDefault();
    if (team === null) {
      return;
    }
    setError(null);
    setBusy(true);
    try {
      const updated = await renameTeam(team.id, rename);
      setTeam(updated);
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not rename team");
    } finally {
      setBusy(false);
    }
  }

  async function onArchive() {
    if (team === null) {
      return;
    }
    setError(null);
    setBusy(true);
    try {
      setTeam(await archiveTeam(team.id));
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not archive team");
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <button
        type="button"
        className="nav-link"
        onClick={() => navigate("/teams")}
      >
        Back to teams
      </button>

      <h1 style={{ marginTop: 8 }} data-testid="team-heading">
        {team.name}
      </h1>
      <p className="lede">
        <code data-testid="team-slug">{team.slug}</code>
        {team.archivedAt === null ? null : " (archived)"}
      </p>

      <ErrorNotice message={error} />

      {canManage ? (
        <form className="form inline-form" onSubmit={onRename} noValidate>
          <div className="field">
            <label htmlFor="team-rename">Display name</label>
            <input
              id="team-rename"
              required
              value={rename}
              onChange={(event) => setRename(event.target.value)}
            />
            <span className="field-hint">
              The slug is permanent. Only the display name can change.
            </span>
          </div>
          <button
            className="btn"
            type="submit"
            data-testid="rename-team"
            disabled={busy || rename === "" || rename === team.name}
          >
            Rename
          </button>
          {team.archivedAt === null ? (
            <button
              type="button"
              className="btn btn-quiet"
              data-testid="archive-team"
              disabled={busy}
              onClick={onArchive}
            >
              Archive team
            </button>
          ) : null}
        </form>
      ) : null}

      <MembersPanel
        team={team}
        orgMembers={orgMembers}
        canManage={canManage}
      />
      <KeysPanel team={team} canManage={canManage} />
    </>
  );
}
