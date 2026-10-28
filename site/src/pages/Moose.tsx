import { Layout } from "../components/Layout";

const MOOSE_REPO_URL = "https://github.com/change-fabric/moose";

const SURFACES = [
  {
    name: "MCP",
    detail: "a streamable HTTP endpoint at /mcp for agents that speak the Model Context Protocol.",
  },
  {
    name: "REST",
    detail:
      "a /v1 API authenticated with personal access tokens, each cross-checked against the caller's tailnet identity.",
  },
  { name: "CLI", detail: "the moose command line client." },
];

const DEPLOY_TARGETS = [
  "Docker Compose on a machine you run yourself.",
  "AWS via Terraform: Lambda behind a private API Gateway, DynamoDB, and a small EC2 Tailscale relay.",
];

export function Moose() {
  return (
    <Layout>
      <section className="moose">
        <header className="page-head">
          <img src="/brand/moose.png" width="64" height="64" alt="moose logo" />
          <p className="eyebrow">Related project</p>
          <h1>moose</h1>
          <p className="section-lede">
            moose is an open source, self-hostable framework for federated data access. It gives
            coding agents read access to your data where it already lives, through pluggable
            connectors. It is a separate, MIT-licensed project, not part of the Change Fabric spec.
          </p>
        </header>

        <h2>What it is</h2>
        <p>
          moose runs inside your own Tailscale tailnet and is reachable only from it. Each data
          source plugs in as a connector, and moose passes content through to the agent on request
          rather than copying it into a store of its own. Google Drive is the first connector.
        </p>

        <h2>Surfaces</h2>
        <ul>
          {SURFACES.map((surface) => (
            <li key={surface.name}>
              <strong>{surface.name}</strong>: {surface.detail}
            </li>
          ))}
        </ul>

        <h2>Deploy targets</h2>
        <ul>
          {DEPLOY_TARGETS.map((target) => (
            <li key={target}>{target}</li>
          ))}
        </ul>

        <h2>Semantic search</h2>
        <p>
          Opt-in semantic (vector) search is in progress. When enabled, moose stores only derived
          vectors, re-checks every hit live against its source before returning it, and keeps no data
          warehouse of your documents.
        </p>

        <p>Status: pre-alpha. Expect breaking changes.</p>

        <p>
          <a href={MOOSE_REPO_URL} target="_blank" rel="noopener noreferrer">
            Source on GitHub<span aria-hidden="true"> &#8599;</span>
            <span className="sr-only"> (opens in a new tab)</span>
          </a>
        </p>
      </section>
    </Layout>
  );
}
