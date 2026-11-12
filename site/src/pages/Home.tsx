import { useEffect } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { CURRENT_VERSION, specPath } from "../spec";
import { MediaSlot } from "../components/MediaSlot";

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

// Claude Code is native; OpenCode and Pi are wired by install.rb. Codex and
// Copilot adapters are planned, shown here ahead of them for the prototype.
const HARNESSES = [
  { id: "claude", url: "https://claude.com/product/claude-code", name: "Claude Code", showName: false },
  { id: "openai", url: "https://openai.com/codex/", name: "OpenAI Codex", showName: false },
  { id: "copilot", url: "https://github.com/copilot", name: "GitHub Copilot", showName: false },
  { id: "opencode", url: "https://opencode.ai/", name: "OpenCode", showName: false },
  { id: "pi", url: "https://pi.dev/", name: "Pi", showName: true },
] as const;

// The toolkit map: the same five layers the SVG draws, top to bottom, each
// linking to its filtered reference list. Keep this list and
// public/diagrams/toolkit-map.svg in step.
const MAP_LAYERS = [
  { group: "modes", name: "Merge modes", detail: "How far the agent may go: local-only, merge-ready, admin-bypass, yolo." },
  { group: "workflow", name: "Workflow commands", detail: "The work itself: plan, drive, walkthrough, diagram, narrate." },
  { group: "rubrics", name: "Rubrics", detail: "Applied per change: react, ruby, docker, and more." },
  { group: "lanes", name: "Audit lanes", detail: "Feed the change gate: a11y, k6, zap, qa, testcases." },
  { group: "hooks", name: "Hooks", detail: "Enforce it: the review gate, the merge guard, the tag guard." },
] as const;

function Lane({ n, role, name, detail, url }: (typeof LANES)[number]) {
  return (
    <li>
      <a className="lane" href={url} target="_blank" rel="noopener noreferrer">
        <span className="lane-n" aria-hidden="true">{n}</span>
        <span className="lane-role">{role}</span>
        <span className="lane-name">
          {name}
          <span className="sr-only"> (opens in a new tab)</span>
        </span>
        <span className="lane-detail">{detail}</span>
      </a>
    </li>
  );
}

// Loads the hero light after first paint, off the critical path, and only
// where it can run: never in an automated browser, so screenshots and audits
// see the static texture; never under reduced motion; and never where the
// stylesheet hides the texture (phones, forced colors), so no WebGL context
// or image request is spent on a decoration nobody sees. The media query is
// watched, so turning reduced motion on mid-visit stops the light at once.
const OFF_QUERY = "(max-width: 640px), (forced-colors: active), (prefers-reduced-motion: reduce)";

function useFabricLight() {
  useEffect(() => {
    if (navigator.webdriver) return;
    const hidden = matchMedia(OFF_QUERY);
    let unmount: (() => void) | undefined;
    let pending: number | undefined;
    let cancelled = false;
    const start = () => {
      pending = undefined;
      const shell = document.querySelector<HTMLElement>(".shell");
      if (!shell) return;
      import("../fabricLight").then((m) => {
        if (!cancelled && !hidden.matches && !unmount) unmount = m.mount(shell);
      });
    };
    const stop = () => {
      if (pending !== undefined) {
        if ("cancelIdleCallback" in window) cancelIdleCallback(pending);
        else clearTimeout(pending);
        pending = undefined;
      }
      unmount?.();
      unmount = undefined;
    };
    const sync = () => {
      if (hidden.matches) stop();
      else if (!unmount && pending === undefined)
        pending = "requestIdleCallback" in window ? requestIdleCallback(start) : (setTimeout(start, 200) as unknown as number);
    };
    hidden.addEventListener("change", sync);
    sync();
    return () => {
      cancelled = true;
      hidden.removeEventListener("change", sync);
      stop();
    };
  }, []);
}

export function Home() {
  useFabricLight();
  return (
    <Layout>
      <div className="home">
        <section className="hero" aria-labelledby="hero-title">
          <p className="hero-eyebrow">Local-first release quality</p>
          <h1 id="hero-title">Quality before merge.</h1>
          <p className="hero-subtitle">An open-source spec and agent skills that check your app locally, in containers.</p>
          <p className="hero-copy">
            Load, accessibility, security and responsive checks run against your booted app
            before a change merges.
          </p>
          <div className="hero-actions">
            <a className="btn" href="#get-started">
              Get started <span aria-hidden="true">&rarr;</span>
            </a>
            <a className="btn btn-quiet" href={specPath(CURRENT_VERSION)}>
              Read the spec
            </a>
          </div>
          <MediaSlot slot="walkthrough-self" />
          <div className="harnesses" aria-labelledby="harnesses-title">
            <p className="harnesses-title" id="harnesses-title">
              Works with your coding agents
            </p>
            <ul className="harness-list">
              {HARNESSES.map((h) => (
                <li key={h.name} className={`harness harness-${h.id}`}>
                  <a className="harness-link" href={h.url} target="_blank" rel="noopener noreferrer">
                    <span className="harness-mark" aria-hidden="true" />
                    {h.showName ? (
                      <span className="harness-name">{h.name}</span>
                    ) : (
                      <span className="sr-only">{h.name}</span>
                    )}
                    <span className="sr-only"> (opens in a new tab)</span>
                  </a>
                </li>
              ))}
            </ul>
          </div>
        </section>

        <section className="home-section" aria-labelledby="map-title">
          <h2 id="map-title">What the toolkit installs.</h2>
          <div className="toolkit-map">
            <img
              className="toolkit-map-img"
              src="/diagrams/toolkit-map.svg"
              width={560}
              height={464}
              alt="The toolkit as five stacked layers: merge modes, workflow commands, rubrics, audit lanes, and hooks. The list beside it names the same layers."
              loading="lazy"
              decoding="async"
            />
            <ul className="toolkit-map-list">
              {MAP_LAYERS.map((layer) => (
                <li key={layer.group}>
                  <a href={`/reference?group=${layer.group}`}>{layer.name}</a>
                  <span>{layer.detail}</span>
                </li>
              ))}
            </ul>
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
