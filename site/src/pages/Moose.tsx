import type { ReactNode } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { Mark } from "../components/Logo";

const MOOSE_REPO_URL = "https://github.com/change-fabric/moose";
const README_URL = `${MOOSE_REPO_URL}#readme`;

const META = ["MIT licensed", "Self-hosted", "MCP · REST · CLI", "Pre-alpha"];

// The three surfaces over moose's one core, numbered like the homepage lanes.
const INTERFACES = [
  {
    n: "01",
    name: "MCP",
    detail: "A streamable HTTP endpoint at /mcp for agents that speak the Model Context Protocol.",
  },
  {
    n: "02",
    name: "REST",
    detail:
      "A /v1 API authenticated with personal access tokens, each cross-checked against the caller's tailnet identity.",
  },
  { n: "03", name: "CLI", detail: "The moose command line client, for direct access and scripting." },
];

// Both deploy paths, each linked to its own section of the moose README.
const DEPLOYS = [
  {
    name: "Docker Compose",
    detail: "Run moose on a machine you manage. No published ports; it joins your tailnet itself.",
    href: `${MOOSE_REPO_URL}#mac-mini`,
  },
  {
    name: "AWS via Terraform",
    detail: "Lambda behind a private API Gateway, DynamoDB, and a small EC2 Tailscale relay.",
    href: `${MOOSE_REPO_URL}#aws`,
  },
];

// The README's own local dev hub: plain HTTP, a fixed identity, refused in
// prod. Go runs in Docker through ./scripts/go, so nothing else is installed.
const QUICK_START = `git clone https://github.com/change-fabric/moose.git
cd moose

# Start a local dev hub (plain HTTP, fixed identity, refused in prod)
MOOSE_ENV=dev MOOSE_LISTEN=127.0.0.1:8787 MOOSE_DEV_IDENTITY=me@example.com \\
  MOOSE_BOOTSTRAP_ADMIN=me@example.com ./scripts/go run ./cmd/moosed

# In a second shell, mint a first token and check who you are
export MOOSE_CREDENTIALS=/src/dist/dev-credentials.json
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

export function Moose() {
  return (
    <Layout>
      <div className="home moose">
        <section className="hero moose-hero" aria-labelledby="moose-title">
          <p className="hero-eyebrow">Related project / Open source</p>
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
          <ul className="moose-meta" aria-label="Project facts">
            {META.map((m) => (
              <li key={m}>{m}</li>
            ))}
          </ul>
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
          <ol className="moose-arch" aria-label="How a request flows">
            <li className="moose-node">
              <span className="moose-node-title">Coding agents</span>
              <span className="moose-node-sub">Claude Code, opencode, Pi</span>
              <span className="moose-node-tag">MCP · REST · CLI</span>
            </li>
            <li className="moose-link" aria-hidden="true">&harr;</li>
            <li className="moose-node moose-node-hub">
              <img src="/brand/moose.png" width="40" height="40" alt="" />
              <span className="moose-node-title">moose</span>
              <span className="moose-node-sub">Inside your tailnet</span>
            </li>
            <li className="moose-link" aria-hidden="true">&harr;</li>
            <li className="moose-node">
              <span className="moose-node-title">Your data sources</span>
              <span className="moose-node-sub">Google Drive, the first connector</span>
              <span className="moose-node-tag">Pluggable connectors</span>
            </li>
          </ol>
          <p className="home-note moose-arch-note">Private, on-demand access · No data replication</p>
        </section>

        <section className="home-section" aria-labelledby="ifaces-title">
          <h2 id="ifaces-title">Three interfaces. One gateway.</h2>
          <ul className="moose-ifaces">
            {INTERFACES.map((i) => (
              <li key={i.name}>
                <span className="lane-n" aria-hidden="true">{i.n}</span>
                <h3>{i.name}</h3>
                <p>{i.detail}</p>
              </li>
            ))}
          </ul>
          <p className="home-note">
            Opt-in semantic search is in progress. It stores only derived vectors and re-checks
            every hit live against its source before returning it.
          </p>
        </section>

        <section className="home-section" aria-labelledby="deploy-title">
          <h2 id="deploy-title">Deploy it your way.</h2>
          <ul className="moose-deploys">
            {DEPLOYS.map((d) => (
              <li key={d.name}>
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
            Try it locally first. Go runs in Docker, so Docker and git are all you need.
          </p>
          <div className="moose-code">
            <CodeBlock code={QUICK_START} label="bash" />
          </div>
          <p className="home-note">
            Then follow the <External href={README_URL}>setup guide</External> to connect Google
            Drive and your agents.
          </p>
        </section>

        <section className="home-section" aria-labelledby="family-title">
          <h2 id="family-title">Independent projects. Shared philosophy.</h2>
          <div className="moose-family">
            <p className="home-lede">
              moose is a separate, MIT-licensed project, not part of the Change Fabric spec. It
              focuses on private, federated data access for coding agents; Change Fabric focuses on
              software quality and release readiness. Both favor local control and infrastructure
              you own. <a href="/">Learn more about Change Fabric <span aria-hidden="true">&rarr;</span></a>
            </p>
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

        <nav className="moose-foot" aria-label="moose resources">
          <External href={MOOSE_REPO_URL}>GitHub</External>
          <External href={README_URL}>Documentation</External>
          <External href={`${MOOSE_REPO_URL}/blob/main/LICENSE`}>License (MIT)</External>
        </nav>
      </div>
    </Layout>
  );
}
