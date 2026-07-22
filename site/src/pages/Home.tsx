import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { CURRENT_VERSION, specPath } from "../spec";

const LANES = [
  { name: "k6", role: "load", detail: "Grades every threshold under load.", url: "https://github.com/grafana/k6" },
  { name: "axe-core", role: "accessibility", detail: "Fails on violations above an impact threshold.", url: "https://github.com/dequelabs/axe-core" },
  { name: "OWASP ZAP", role: "security", detail: "Passive baseline: headers, cookies, known CVEs.", url: "https://github.com/zaproxy/zaproxy" },
  { name: "browserless", role: "responsive UX", detail: "Every route at every viewport.", url: "https://github.com/browserless/browserless" },
];

// A realistic, generic CHANGE.md a visitor can copy into their own repo. It
// covers both frontmatter blocks and a short prose body, matching the shape of
// reference/CHANGE.template.md without being tied to any one project.
const EXAMPLE_CHANGE_MD = `---
change_config:
  project: acme-web
  boot:
    up: docker compose up -d --build web
    down: docker compose down
    target_url: http://web:3000
    health:
      url: http://localhost:3000/health
  lanes:
    a11y:
      routes: ["/", "/login", "/dashboard"]
      threshold: serious
    zap:
      targets: ["http://web:3000"]
    browserless:
      routes: ["/", "/dashboard"]
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: desktop, width: 1440, height: 900 }
change_policy:
  promotion:
    staging: { require_change_pass: true }
    production: { require_change_pass: true }
  admin_bypass:
    allowed: false
---

# Change management for acme-web

Feature branches merge to \`main\` behind a review. Promotion PRs go
\`main -> staging -> production\`; each requires a passing change fabric run.
Admin-bypass merging is not used here.
`;

function LaneCard({ name, role, detail, url }: (typeof LANES)[number]) {
  return (
    <a className="lane" href={url} target="_blank" rel="noopener noreferrer">
      <span className="lane-role">{role}</span>
      <span className="lane-name">
        {name}
        <span className="lane-arrow" aria-hidden="true">
          &#8599;
        </span>
      </span>
      <span className="lane-detail">{detail}</span>
    </a>
  );
}

export function Home() {
  return (
    <Layout>
      <section className="hero">
        <h1>A dockerized local release-quality gate.</h1>
        <p>
          Four audit lanes run against a locally booted app, in ephemeral digest-pinned
          containers, gating a release before it merges.
        </p>
      </section>

      <section className="lanes" aria-label="Audit lanes">
        {LANES.map((lane) => (
          <LaneCard key={lane.name} {...lane} />
        ))}
      </section>

      <section className="contract">
        <h2>One file per repo</h2>
        <p className="section-lede">
          The root <code>CHANGE.md</code> declares how a repo is audited (<code>change_config</code>)
          and governed (<code>change_policy</code>). Copy this to get started.
        </p>
        <CodeBlock code={EXAMPLE_CHANGE_MD} label="CHANGE.md" />
        <p className="contract-footnote">
          Every field is documented in the{" "}
          <a href={specPath(CURRENT_VERSION)}>frontmatter spec</a>.
        </p>
      </section>
    </Layout>
  );
}
