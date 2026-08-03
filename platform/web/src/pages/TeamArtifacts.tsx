import { useEffect, useState } from "react";
import { listArtifacts, listTeams, type Artifact, type Team } from "../api";
import { ErrorNotice } from "../components/Notice";
import { navigate } from "../router";

/**
 * What a team has published.
 *
 * Every row links straight at the artifacts host rather than proxying anything
 * through this app. That is the whole point of the arrangement: the bytes are
 * served by CloudFront under a signed cookie, so the app's job here is to say
 * which runs exist and let the browser go and get them. A person who is not on
 * the team can still see this listing, because knowing that a team published
 * something is organization-level information; opening one is not, and the
 * artifacts host will send them to the authorize screen and refuse there.
 *
 * The table is deliberately flat and sorted newest first. A findings run is
 * looked at because something just happened, so the useful ordering is the one
 * that puts what just happened at the top.
 */

function formatWhen(value: string | null): string {
  if (value === null) {
    return "not published";
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "not published"
    : date.toISOString().slice(0, 16).replace("T", " ");
}

function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${Math.round(bytes / 1024)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Green for a clean run, the archived tone for anything else. Same tags the rest of the app uses. */
function statusClass(status: string): string {
  return status === "pass" ? "role-tag role-owner" : "role-tag role-archived";
}

export function TeamArtifacts({ teamId }: { teamId: string }) {
  const [team, setTeam] = useState<Team | null>(null);
  const [artifacts, setArtifacts] = useState<Artifact[] | null>(null);
  const [cursor, setCursor] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);

  useEffect(() => {
    let current = true;

    async function run() {
      const teams = await listTeams();
      const found = teams.find((row) => row.id === teamId) ?? null;
      const page = await listArtifacts(teamId);
      if (!current) {
        return;
      }
      setTeam(found);
      setArtifacts(page.artifacts);
      setCursor(page.nextCursor);
    }

    run().catch((cause: unknown) => {
      if (current) {
        setError(
          cause instanceof Error ? cause.message : "could not load artifacts",
        );
      }
    });

    return () => {
      current = false;
    };
  }, [teamId]);

  async function onMore() {
    if (cursor === null) {
      return;
    }
    setLoadingMore(true);
    try {
      const page = await listArtifacts(teamId, cursor);
      // Appended rather than replaced, and the cursor advanced from the page
      // that just arrived, so paging forward twice cannot repeat a row.
      setArtifacts((rows) => [...(rows ?? []), ...page.artifacts]);
      setCursor(page.nextCursor);
    } catch (cause: unknown) {
      setError(cause instanceof Error ? cause.message : "could not load more");
    } finally {
      setLoadingMore(false);
    }
  }

  return (
    <>
      <button
        type="button"
        className="nav-link"
        onClick={() => navigate(`/teams/${teamId}`)}
      >
        Back to team
      </button>

      <h1 style={{ marginTop: 8 }} data-testid="artifacts-heading">
        Findings
      </h1>
      <p className="lede">
        Everything {team?.name ?? "this team"} has published. Opening one takes
        you to the artifacts host, which checks your team membership before it
        shows you anything.
      </p>

      <ErrorNotice message={error} />

      {artifacts === null ? (
        <p className="muted">Loading findings.</p>
      ) : artifacts.length === 0 ? (
        <p className="muted" data-testid="artifacts-empty">
          Nothing published yet.
        </p>
      ) : (
        <>
          <div className="table-scroll">
            <table className="members-table" data-testid="artifacts-table">
              <thead>
                <tr>
                  <th scope="col">Run</th>
                  <th scope="col">Status</th>
                  <th scope="col">Branch</th>
                  <th scope="col">Contributor</th>
                  <th scope="col">Size</th>
                  <th scope="col">Generated</th>
                  <th scope="col" />
                </tr>
              </thead>
              <tbody>
                {artifacts.map((artifact) => (
                  <tr
                    key={artifact.id}
                    data-testid={`artifact-row-${artifact.shortId}`}
                  >
                    <td className="muted">
                      <code>{artifact.shortId}</code>
                    </td>
                    <td>
                      <span
                        className={statusClass(artifact.status)}
                        data-testid={`artifact-status-${artifact.shortId}`}
                      >
                        {artifact.status}
                      </span>
                      {artifact.failCount > 0 || artifact.warnCount > 0 ? (
                        <span className="muted">
                          {" "}
                          {artifact.failCount} fail, {artifact.warnCount} warn
                        </span>
                      ) : null}
                    </td>
                    <td className="muted">{artifact.branch ?? ""}</td>
                    <td className="muted">{artifact.contributorLabel ?? ""}</td>
                    <td className="muted">{formatSize(artifact.byteSize)}</td>
                    <td className="muted">
                      {formatWhen(artifact.generatedAt)}
                    </td>
                    <td>
                      {artifact.publishedAt === null ? (
                        <span className="muted">incomplete</span>
                      ) : (
                        // A plain anchor, not a router navigation: this leaves
                        // the app for another host entirely.
                        <a
                          className="nav-link"
                          href={artifact.viewerUrl}
                          data-testid={`open-artifact-${artifact.shortId}`}
                        >
                          Open
                        </a>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {cursor === null ? null : (
            <button
              type="button"
              className="btn btn-quiet"
              data-testid="load-more-artifacts"
              disabled={loadingMore}
              onClick={onMore}
            >
              {loadingMore ? "Loading" : "Load more"}
            </button>
          )}
        </>
      )}
    </>
  );
}
