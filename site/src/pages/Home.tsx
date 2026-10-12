import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { CURRENT_VERSION, specPath } from "../spec";
import { SUBTITLE } from "../components/Logo";

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

// A generic two-app monorepo registry, matching the shape of the "apps"
// worked example in the frontmatter spec (0.4.0) without naming a real client.
const MONOREPO_APPS_YAML = `# CHANGE.md (repo root)
change_config:
  project: acme-platform
  apps:
    portal:
      config: apps/portal/CHANGE.app.yml
      description: Authenticated multi-route app
    marketing:
      config: apps/marketing/CHANGE.app.yml
      description: Static, unauthenticated site
change_policy:
  promotion:
    production:
      require_change_pass: true
      apps: [portal]   # omit to require every registered app
`;

function LaneRow({ name, role, detail, url }: (typeof LANES)[number]) {
  return (
    <li>
      <a className="lane" href={url} target="_blank" rel="noopener noreferrer">
        <span className="lane-name">{name}</span>
        <span className="lane-detail">{detail}</span>
        <span className="lane-role">{role}</span>
      </a>
    </li>
  );
}

export function Home() {
  return (
    <Layout>
      <section className="hero">
        <h1>{SUBTITLE}</h1>
        <p>
          A dockerized release-quality gate: four audit lanes run against a locally booted
          app, in ephemeral digest-pinned containers, before a change merges.
        </p>
      </section>

      <ul className="lanes" aria-label="Audit lanes">
        {LANES.map((lane) => (
          <LaneRow key={lane.name} {...lane} />
        ))}
      </ul>

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

      <section className="contract">
        <h2>One repo, many apps</h2>
        <p className="section-lede">
          Each app in the monorepo gets its own <code>CHANGE.app.yml</code>, listed under{" "}
          <code>change_config.apps</code> in the root file. One <code>change_policy</code> still
          governs the whole repo, and each promotion rule picks which apps it requires a pass from.
        </p>
        <CodeBlock code={MONOREPO_APPS_YAML} label="CHANGE.md" />
      </section>
    </Layout>
  );
}
