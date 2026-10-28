import type { ReactNode } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { Mark } from "../components/Logo";

const MOOSE_REPO_URL = "https://github.com/change-fabric/moose";
const README_URL = `${MOOSE_REPO_URL}#readme`;

// The three surfaces over moose's one core, numbered like the homepage lanes,
// each with the path or command it answers on.
const INTERFACES = [
  {
    n: "01",
    name: "MCP",
    id: "/mcp",
    detail: "A streamable HTTP endpoint for agents that speak the Model Context Protocol.",
  },
  {
    n: "02",
    name: "REST",
    id: "/v1",
    detail:
      "An API authenticated with personal access tokens, each cross-checked against the caller's tailnet identity.",
  },
  { n: "03", name: "CLI", id: "moose", detail: "The command line client, for direct access and scripting." },
];

// Third-party marks are CC0 Simple Icons (public/brand/tech) or the homepage's
// harness marks, painted in one muted ink as masks. The agents are the three
// the moose README documents a setup for.
const AGENTS = [
  { id: "claude", name: "Claude Code" },
  { id: "opencode", name: "OpenCode" },
  { id: "pi", name: "Pi" },
];

// Both deploy paths, each linked to its own section of the moose README.
const DEPLOYS = [
  {
    name: "Docker Compose",
    marks: [{ id: "docker", name: "Docker" }],
    detail: "Run moose on a machine you manage. No published ports; it joins your tailnet itself.",
    href: `${MOOSE_REPO_URL}#mac-mini`,
  },
  {
    name: "AWS via Terraform",
    marks: [
      { id: "aws", name: "AWS" },
      { id: "terraform", name: "Terraform" },
    ],
    detail: "Lambda behind a private API Gateway, DynamoDB, and a small EC2 Tailscale relay.",
    href: `${MOOSE_REPO_URL}#aws`,
  },
];

// The README's own local dev hub, split into its two shells. ./scripts/go runs
// Go in the golang image with host networking, so the credentials path is the
// repo as mounted inside that container.
const START_HUB = `git clone https://github.com/change-fabric/moose.git
cd moose
MOOSE_ENV=dev MOOSE_LISTEN=127.0.0.1:8787 MOOSE_DEV_IDENTITY=me@example.com \\
  MOOSE_BOOTSTRAP_ADMIN=me@example.com ./scripts/go run ./cmd/moosed
`;

const FIRST_TOKEN = `export MOOSE_CREDENTIALS=/src/dist/dev-credentials.json
./scripts/go run ./cmd/moose token bootstrap --url http://127.0.0.1:8787 --name dev
./scripts/go run ./cmd/moose whoami
`;

function External({ href, children, className }: { href: string; children: ReactNode; className?: string }) {
  return (
    <a className={className} href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}

function TechMark({ id, name }: { id: string; name: string }) {
  return (
    <span className={`tech-mark tech-${id}`} role="img" aria-label={name} />
  );
}

export function Moose() {
  return (
    <Layout>
      <div className="home moose">
        <section className="hero moose-hero" aria-labelledby="moose-title">
          <p className="hero-eyebrow">
            Related project / Open source <span className="status-tag">Pre-alpha</span>
          </p>
          <div className="moose-hero-head">
            <img className="moose-logo" src="/brand/moose.png" width="96" height="96" alt="moose logo" />
            <h1 id="moose-title">
              Your data stays put. <span className="moose-h1-line">Your agents get access.</span>
            </h1>
          </div>
          <p className="hero-copy">
            moose is a self-hosted framework for federated data access. It gives coding agents read
            access to your data where it already lives, through pluggable connectors.
          </p>
          <p className="moose-meta">MIT licensed · Self-hosted · MCP, REST and CLI</p>
          <div className="hero-actions">
            <a className="btn" href="#get-started">
              Get started <span aria-hidden="true">&rarr;</span>
            </a>
            <External className="btn btn-quiet" href={MOOSE_REPO_URL}>
              View on GitHub
            </External>
          </div>
        </section>

        <section className="home-section" aria-labelledby="arch-title">
          <h2 id="arch-title">Your data, where it already lives.</h2>
          <p className="home-lede">
            Connectors plug into the tools you already use. moose runs inside your Tailscale tailnet
            and fetches content on demand, so it never copies your data into a store of its own.
          </p>
          {/* Agents and moose share the tailnet; the source sits outside it and
              is read only when an agent asks. */}
          <div className="moose-arch" role="group" aria-label="How a request flows">
            <div className="moose-tailnet">
              <p className="moose-tailnet-label">
                <TechMark id="tailscale" name="Tailscale" /> Your tailnet
              </p>
              <div className="moose-node">
                <span className="moose-node-title">Coding agents</span>
                <span className="moose-marks">
                  {AGENTS.map((a) => (
                    <TechMark key={a.id} {...a} />
                  ))}
                </span>
              </div>
              <p className="moose-link">
                <span className="moose-link-label">MCP · REST · CLI</span>
                <span className="moose-link-arrow" aria-hidden="true" />
              </p>
              <div className="moose-hub">
                <img src="/brand/moose.png" width="56" height="56" alt="" />
                <span className="moose-hub-title">moose</span>
                <span className="moose-hub-sub">Gateway on your tailnet</span>
              </div>
            </div>
            <p className="moose-link">
              <span className="moose-link-label">Reads on demand</span>
              <span className="moose-link-arrow" aria-hidden="true" />
            </p>
            <div className="moose-node">
              <span className="moose-node-title">Your data sources</span>
              <span className="moose-marks">
                <TechMark id="googledrive" name="Google Drive" />
              </span>
              <span className="moose-node-sub">Google Drive is the first connector</span>
            </div>
          </div>
          <p className="home-note moose-arch-note">Private, on-demand access · No data replication</p>
        </section>

        <section className="home-section" aria-labelledby="ifaces-title">
          <h2 id="ifaces-title">Three interfaces. One gateway.</h2>
          <ul className="moose-ifaces">
            {INTERFACES.map((i) => (
              <li key={i.name}>
                <span className="lane-n" aria-hidden="true">{i.n}</span>
                <h3>
                  {i.name} <code>{i.id}</code>
                </h3>
                <p>{i.detail}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="home-section" aria-labelledby="deploy-title">
          <h2 id="deploy-title">Deploy it your way.</h2>
          <ul className="moose-deploys">
            {DEPLOYS.map((d) => (
              <li key={d.name}>
                <span className="moose-marks">
                  {d.marks.map((m) => (
                    <TechMark key={m.id} {...m} />
                  ))}
                </span>
                <h3>{d.name}</h3>
                <p>{d.detail}</p>
                <External href={d.href}>
                  View setup guide <span aria-hidden="true">&rarr;</span>
                </External>
              </li>
            ))}
          </ul>
        </section>

        <section className="home-section" id="get-started" aria-labelledby="start-title">
          <h2 id="start-title">Get up and running.</h2>
          <p className="home-lede">
            You need git and Docker, not Go: <code>./scripts/go</code> runs the Go toolchain in the
            official golang image with host networking. On Docker Desktop, turn host networking on
            first.
          </p>
          <ol className="moose-steps">
            <li>
              <h3>Start a dev hub</h3>
              <p>Plain HTTP and a fixed identity, for trying moose locally. It refuses to run in prod.</p>
              <div className="moose-code">
                <CodeBlock code={START_HUB} label="shell 1" />
              </div>
            </li>
            <li>
              <h3>Mint a token and check who you are</h3>
              <p>
                In a second shell. <code>/src</code> is the repo as mounted inside the Go container.
              </p>
              <div className="moose-code">
                <CodeBlock code={FIRST_TOKEN} label="shell 2" />
              </div>
            </li>
          </ol>
          <p className="home-note">
            Then follow the <External href={README_URL}>setup guide</External> to connect Google
            Drive and your agents.
          </p>
        </section>

        <aside className="home-section moose-roadmap" aria-labelledby="roadmap-title">
          <p className="hero-eyebrow">
            <span className="status-tag">In development</span>
          </p>
          <h2 id="roadmap-title">Semantic search</h2>
          <p className="home-lede">
            Opt-in vector search is being built and is not in a release yet. When enabled, it will
            store only derived vectors and re-check every hit live against its source before
            returning it.
          </p>
        </aside>

        <section className="home-section" aria-labelledby="family-title">
          <h2 id="family-title">Independent projects. Shared philosophy.</h2>
          <div className="moose-family">
            <div>
              <p className="home-lede">
                moose is a separate, MIT-licensed project, not part of the Change Fabric spec. It
                focuses on private, federated data access for coding agents; Change Fabric focuses
                on software quality and release readiness. Both favor local control and
                infrastructure you own.
              </p>
              <ul className="moose-links" aria-label="moose resources">
                <li>
                  <External href={MOOSE_REPO_URL}>GitHub</External>
                </li>
                <li>
                  <External href={README_URL}>Documentation</External>
                </li>
                <li>
                  <External href={`${MOOSE_REPO_URL}/blob/main/LICENSE`}>License (MIT)</External>
                </li>
                <li>
                  <a href="/">About Change Fabric <span aria-hidden="true">&rarr;</span></a>
                </li>
              </ul>
            </div>
            <ul className="moose-pair">
              <li>
                <img src="/brand/moose.png" width="48" height="48" alt="" />
                <span className="moose-pair-name">moose</span>
                <span className="moose-pair-sub">Your data, your infrastructure</span>
              </li>
              <li>
                <Mark size={48} />
                <span className="moose-pair-name">change fabric</span>
                <span className="moose-pair-sub">Quality before merge</span>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layout>
  );
}
