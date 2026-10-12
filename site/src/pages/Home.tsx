import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { CURRENT_VERSION, specPath } from "../spec";
import { SUBTITLE } from "../components/Logo";

// The four audit lanes the gate boots an app for. Category leads, the tool is
// the identifier, and the line says what the lane actually checks.
const LANES = [
  { n: "01", role: "Load", name: "k6", detail: "Fails the run when any declared threshold breaks under load.", url: "https://github.com/grafana/k6" },
  { n: "02", role: "Accessibility", name: "axe-core", detail: "Fails on violations at or above the impact threshold you set.", url: "https://github.com/dequelabs/axe-core" },
  { n: "03", role: "Security", name: "OWASP ZAP", detail: "Passive baseline scan: headers, cookies, known CVEs.", url: "https://github.com/zaproxy/zaproxy" },
  { n: "04", role: "Responsive UX", name: "browserless", detail: "Renders every route at every viewport you list.", url: "https://github.com/browserless/browserless" },
];

// The smallest useful CHANGE.md: both frontmatter blocks, three lanes, one
// promotion rule. ZAP with no targets scans the lane base url. The spec,
// linked below, carries the full shape.
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
    zap: {}
    browserless:
      routes: ["/", "/dashboard"]
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: desktop, width: 1440, height: 900 }
change_policy:
  promotion:
    production: { require_change_pass: true }
---
`;

function Lane({ n, role, name, detail, url }: (typeof LANES)[number]) {
  return (
    <li>
      <a className="lane" href={url} target="_blank" rel="noopener noreferrer">
        <span className="lane-role">
          <span className="lane-n" aria-hidden="true">{n}</span>
          {role}
        </span>
        <span className="lane-name">
          {name}
          <span className="sr-only"> (opens in a new tab)</span>
        </span>
        <span className="lane-detail">{detail}</span>
      </a>
    </li>
  );
}

export function Home() {
  return (
    <Layout>
      <div className="home">
        <section className="hero" aria-labelledby="hero-title">
          <p className="hero-eyebrow">Local-first release quality</p>
          <h1 id="hero-title">Quality before merge.</h1>
          <p className="hero-subtitle">{SUBTITLE}</p>
          <p className="hero-copy">
            Run load, accessibility, security and responsive checks against your app, booted
            locally in containers, before a change merges.
          </p>
          <div className="hero-actions">
            <a className="btn" href="#get-started">
              Get started <span aria-hidden="true">&rarr;</span>
            </a>
            <a className="btn btn-quiet" href={specPath(CURRENT_VERSION)}>
              Read the spec
            </a>
          </div>
        </section>

        <section className="home-section" aria-labelledby="lanes-title">
          <h2 id="lanes-title">Four audits. One gate.</h2>
          <p className="home-lede">
            Each lane runs in its own ephemeral, digest-pinned container. Any failing lane
            blocks the merge.
          </p>
          <ul className="lanes">
            {LANES.map((lane) => (
              <Lane key={lane.name} {...lane} />
            ))}
          </ul>
          <p className="home-note">
            A fifth lane replays your own committed test cases.
          </p>
        </section>

        <section className="home-section" id="get-started" aria-labelledby="start-title">
          <h2 id="start-title">Configure once. Validate every change.</h2>
          <p className="home-lede">
            Add one <code>CHANGE.md</code> at the repo root: how to boot the app, which lanes to
            run, and what each branch requires before promotion.
          </p>
          <CodeBlock code={EXAMPLE_CHANGE_MD} label="CHANGE.md" />
        </section>

        <nav className="home-section further" aria-labelledby="further-title">
          <h2 id="further-title">Further reading</h2>
          <ul>
            <li>
              <a href={specPath(CURRENT_VERSION)}>Frontmatter spec</a>
              <span>Every field, including monorepos with many apps.</span>
            </li>
            <li>
              <a href="/reference">Reference</a>
              <span>Every skill and hook the toolkit installs.</span>
            </li>
            <li>
              <a href="/changelog">Changelog</a>
              <span>What changed in each release.</span>
            </li>
          </ul>
        </nav>
      </div>
    </Layout>
  );
}
