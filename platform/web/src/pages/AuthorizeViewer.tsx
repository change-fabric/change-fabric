import { useEffect, useState } from "react";
import { authorizeViewer, listTeams } from "../api";
import { ErrorNotice } from "../components/Notice";
import { Shell } from "../components/Shell";
import { navigate } from "../router";

/**
 * The one screen a person never chooses to visit.
 *
 * They followed a link to a findings run, the artifacts host noticed they had no
 * CloudFront cookie yet, and it sent them here with two things: where they were
 * going (`next`) and which team's files they were asking for (`team`, a slug,
 * because the edge only ever sees the path). This screen turns that into
 * cookies and sends them back.
 *
 * It is deliberately a screen and not a silent effect somewhere. Three things
 * can go wrong here and each of them is something a person has to be told: they
 * are not on that team, the team does not exist in the organization they are
 * currently acting as, or the link was malformed. A silent redirect loop would
 * report all three as nothing happening.
 *
 * The open-redirect question is settled by the server rather than here. `next`
 * arrives in a query string, so it is attacker-supplied by construction; it is
 * followed only after the API has said which prefix it just authorised, and only
 * if `next` is inside it. A `next` pointing anywhere else is discarded and the
 * person is sent to the team's own viewer root instead, which is where they were
 * plainly trying to go.
 */

type State =
  | { status: "working" }
  | { status: "failed"; message: string }
  | { status: "done"; destination: string };

function readQuery(): { next: string; team: string } {
  const query = new URLSearchParams(window.location.search);
  return {
    next: query.get("next") ?? "",
    team: query.get("team") ?? "",
  };
}

export function AuthorizeViewer() {
  const [state, setState] = useState<State>({ status: "working" });

  useEffect(() => {
    let current = true;

    async function run() {
      const { next, team } = readQuery();
      if (team === "") {
        throw new Error(
          "this link did not say which team's artifacts it was for",
        );
      }

      // The edge knows the slug; the API authorises by id. Resolving through
      // the caller's own team list rather than by asking the API to accept a
      // slug means the lookup is already scoped to the organization they are
      // acting as, and a slug from somewhere else simply is not found.
      const teams = await listTeams();
      const found = teams.find((row) => row.slug === team);
      if (found === undefined) {
        throw new Error(
          `no team called ${team} in the organization you are acting as`,
        );
      }

      const granted = await authorizeViewer(found.id);

      // The server just said what it authorised. Anything outside it is not
      // followed, no matter who put it in the query string.
      const destination = next.startsWith(granted.viewerPrefix)
        ? next
        : granted.viewerPrefix;

      if (!current) {
        return;
      }
      setState({ status: "done", destination });
      // replace, not assign: the back button should return to whatever the
      // person was looking at before, not to this screen, which would
      // immediately send them forward again.
      window.location.replace(destination);
    }

    run().catch((cause: unknown) => {
      if (current) {
        setState({
          status: "failed",
          message:
            cause instanceof Error
              ? cause.message
              : "could not authorise this browser",
        });
      }
    });

    return () => {
      current = false;
    };
  }, []);

  return (
    <Shell>
      <h1 style={{ marginTop: 32 }} data-testid="authorize-heading">
        Opening findings
      </h1>

      {state.status === "working" ? (
        <p className="lede" data-testid="authorize-working">
          Checking your access and preparing this browser.
        </p>
      ) : null}

      {state.status === "done" ? (
        <p className="lede" data-testid="authorize-done">
          Your browser is authorised. Taking you to{" "}
          <code>{state.destination}</code>.
        </p>
      ) : null}

      {state.status === "failed" ? (
        <>
          <ErrorNotice message={state.message} />
          <p className="lede">
            Ask an owner or an admin to add you to the team that published this
            run, then open the link again.
          </p>
          <button
            type="button"
            className="btn btn-quiet"
            onClick={() => navigate("/teams")}
          >
            Back to teams
          </button>
        </>
      ) : null}
    </Shell>
  );
}
