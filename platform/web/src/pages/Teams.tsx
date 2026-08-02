import { useEffect, useState } from "react";
import { createTeam, listTeams, SLUG_PATTERN, type Team } from "../api";
import { navigate } from "../router";
import { ErrorNotice } from "../components/Notice";

/**
 * The organization's contributor teams.
 *
 * The create form is rendered only for an owner or an admin. That is a courtesy,
 * not the rule: the API answers 403 to a member either way. Hiding it means a
 * member is never offered a control whose only outcome is a refusal.
 *
 * Archived teams stay in the list rather than disappearing. A team is archived
 * because it stopped being used, not because it stopped having existed, and its
 * slug still appears in whatever a past run published.
 */
export function Teams({ canManage }: { canManage: boolean }) {
  const [teams, setTeams] = useState<Team[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [generation, setGeneration] = useState(0);

  const slugMalformed = slug !== "" && !SLUG_PATTERN.test(slug);

  useEffect(() => {
    let current = true;
    listTeams()
      .then((rows) => {
        if (current) {
          setTeams(rows);
        }
      })
      .catch((cause: unknown) => {
        if (current) {
          setError(
            cause instanceof Error ? cause.message : "could not load teams",
          );
        }
      });
    return () => {
      current = false;
    };
  }, [generation]);

  async function onSubmit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await createTeam({ name, slug });
      setName("");
      setSlug("");
      setGeneration((n) => n + 1);
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not create team");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <>
      <h1 style={{ marginTop: 16 }}>Contributor teams</h1>
      <p className="lede">
        A team owns the repositories it publishes from and the API keys its
        tooling presents. Somebody can belong to as many teams as they need.
      </p>

      <ErrorNotice message={error} />

      {canManage ? (
        <form className="form inline-form" onSubmit={onSubmit} noValidate>
          <div className="field">
            <label htmlFor="team-name">Team name</label>
            <input
              id="team-name"
              required
              value={name}
              onChange={(event) => setName(event.target.value)}
            />
          </div>
          <div className="field">
            <label htmlFor="team-slug">Slug</label>
            <input
              id="team-slug"
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
              <span className="field-hint">Permanent once created.</span>
            )}
          </div>
          <button
            className="btn"
            type="submit"
            data-testid="create-team"
            disabled={submitting || slugMalformed || name === "" || slug === ""}
          >
            {submitting ? "Creating team" : "Create team"}
          </button>
        </form>
      ) : null}

      {teams === null ? (
        <p className="muted">Loading teams.</p>
      ) : teams.length === 0 ? (
        <p className="muted">No teams yet.</p>
      ) : (
        <div className="table-scroll">
          <table className="members-table" data-testid="teams-table">
            <thead>
              <tr>
                <th scope="col">Team</th>
                <th scope="col">Slug</th>
                <th scope="col">Status</th>
                <th scope="col" />
              </tr>
            </thead>
            <tbody>
              {teams.map((team) => (
                <tr key={team.id} data-testid={`team-row-${team.slug}`}>
                  <td>{team.name}</td>
                  <td className="muted">
                    <code>{team.slug}</code>
                  </td>
                  <td>
                    <span
                      className={
                        team.archivedAt === null
                          ? "role-tag"
                          : "role-tag role-archived"
                      }
                    >
                      {team.archivedAt === null ? "active" : "archived"}
                    </span>
                  </td>
                  <td>
                    <button
                      type="button"
                      className="nav-link"
                      data-testid={`open-team-${team.slug}`}
                      onClick={() => navigate(`/teams/${team.id}`)}
                    >
                      Open
                    </button>
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
