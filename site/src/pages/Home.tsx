import { useEffect } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { CURRENT_VERSION, specPath } from "../spec";
import { MediaSlot } from "../components/MediaSlot";

// The page is one guided path for a newcomer: who it is for, what it is, the
// gate, then the install. Each section is headed by the plain question it
// answers; the order carries the story, so nothing on the page numbers it.

const WHO = [
  { who: "You are new to engineering", why: "You get the habits a senior reviewer would push for, applied while the code is written." },
  { who: "You ship side projects", why: "Your agent stops at a review before every push, so nothing lands half checked." },
  { who: "You run a team repo", why: "Add a gate later: load, accessibility, security and layout checks before a merge." },
] as const;

// Every host install.rb wires today (ARCHITECTURE.md, Host portability). Codex and
// Copilot are named by their CLIs, since only the CLI surfaces are installed;
// desktop, cloud and editor variants are not claimed.
const HARNESSES = [
  { name: "Claude Code", url: "https://claude.com/product/claude-code" },
  { name: "Codex CLI", url: "https://openai.com/codex/" },
  { name: "Copilot CLI", url: "https://github.com/features/copilot" },
  { name: "OpenCode", url: "https://opencode.ai/" },
  { name: "Pi", url: "https://pi.dev/" },
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

// The five gate lanes. Category leads, the tool is the identifier, and the
// line says what makes the lane fail.
const LANES = [
  { role: "Load", name: "k6", detail: "Fails when a declared threshold breaks.", url: "https://github.com/grafana/k6" },
  { role: "Accessibility", name: "axe-core", detail: "Fails at or above the impact you set.", url: "https://github.com/dequelabs/axe-core" },
  { role: "Security", name: "OWASP ZAP", detail: "Passive baseline: headers, cookies.", url: "https://github.com/zaproxy/zaproxy" },
  { role: "Responsive", name: "browserless", detail: "Renders each route at each viewport.", url: "https://github.com/browserless/browserless" },
  { role: "Test cases", name: "testcases", detail: "Replays your committed cases.", url: "/reference/skills/testcases" },
] as const;

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

const INSTALL = `brew tap change-fabric/cf
brew install change-fabric
change-fabric-install
`;

function Lane({ role, name, detail, url }: (typeof LANES)[number]) {
  const external = url.startsWith("http");
  return (
    <li>
      <span className="gate-role">{role}</span>
      <a
        className="gate-tool"
        href={url}
        {...(external ? { target: "_blank", rel: "noopener noreferrer" } : {})}
      >
        {name}
        {external && <span className="sr-only"> (opens in a new tab)</span>}
      </a>
      <span className="gate-detail">{detail}</span>
    </li>
  );
}

// The three layers, drawn inline so the strokes and text follow the theme
// tokens. Only the top layer, Change Fabric, takes the accent.
function LayerDiagram() {
  return (
    <svg className="layers-svg" viewBox="0 0 400 236" role="img" aria-labelledby="layers-t layers-d">
      <title id="layers-t">Layer diagram</title>
      <desc id="layers-d">
        Three stacked layers. Top: Change Fabric, rubrics, commands and hooks. Middle: your coding
        agent, the harness. Bottom: your code and your terminal.
      </desc>
      <rect className="ly-cf" x="1" y="1" width="398" height="70" rx="6" />
      <text className="ly-t" x="20" y="31">Change Fabric</text>
      <text className="ly-m" x="20" y="54">rubrics, commands, hooks</text>
      <rect className="ly-ln" x="1" y="83" width="398" height="70" rx="6" />
      <text className="ly-t" x="20" y="113">Your coding agent</text>
      <text className="ly-m" x="20" y="136">the harness: Claude Code, Codex, Pi</text>
      <rect className="ly-ln" x="1" y="165" width="398" height="70" rx="6" />
      <text className="ly-t" x="20" y="195">Your code</text>
      <text className="ly-m" x="20" y="218">files, terminal, git</text>
    </svg>
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
          <h1 id="hero-title">Your coding agent is the harness. Change Fabric extends it.</h1>
          <p className="hero-copy">
            Your agent writes code faster than you can judge it, and you can't yet tell whether it is
            good or safe to ship. Change Fabric runs inside the agent you already use, checks each
            edit against rubrics from books engineers trust, like Sandi Metz and Martin Fowler, and
            stops the change at a gate before it merges. It is open source, runs on your machine, and
            takes three commands to install, so your next edit is the first one it reviews.
          </p>
          <div className="hero-actions">
            <a className="btn" href="#start-building">
              Start Building
            </a>
          </div>
          <MediaSlot slot="walkthrough-self" />
        </section>

        <section className="home-section" aria-labelledby="for-me-title">
          <h2 id="for-me-title">Is it for me?</h2>
          <p className="home-text">
            You ask it for code and it writes some. It works, mostly. What it lacks is the judgment a
            careful reviewer brings to each edit. If you already ask an agent to write code, this is
            for you. It does not replace your agent or need a new account.
          </p>
          <ul className="who">
            {WHO.map((row) => (
              <li key={row.who}>
                <strong>{row.who}</strong>
                <span>{row.why}</span>
              </li>
            ))}
          </ul>
          <div className="harness-strip" aria-labelledby="harness-strip-title">
            <p id="harness-strip-title">Change Fabric runs inside</p>
            <ul>
              {HARNESSES.map((h) => (
                <li key={h.name}>
                  <a href={h.url} target="_blank" rel="noopener noreferrer">
                    {h.name}
                    <span className="sr-only"> (opens in a new tab)</span>
                  </a>
                </li>
              ))}
            </ul>
          </div>
        </section>

        <section className="home-section" id="what-is-it" aria-labelledby="what-title">
          <h2 id="what-title">What is it?</h2>
          <p className="home-text">
            Change Fabric is a set of skills and hooks your agent loads on its own. It sits on top of
            the agent the way a reviewer sits beside you: it never touches your code directly.
          </p>
          <div className="layers">
            <LayerDiagram />
            <div>
              <ul className="layer-rows">
                <li>
                  <strong>Rubrics</strong>
                  <span>
                    Applied per edit. <code>cf:ruby</code> draws on Sandi Metz's{" "}
                    <i>Practical Object-Oriented Design in Ruby</i>. <code>cf:refactoring</code> draws
                    on Martin Fowler's <i>Refactoring</i>. <code>cf:usability</code> draws on Jakob
                    Nielsen's ten heuristics, and <code>cf:prototyping</code> on Houde and Hill's
                    prototype roles.
                  </span>
                </li>
                <li>
                  <strong>Commands</strong>
                  <span>Work you ask for by name: plan, review, walkthrough.</span>
                </li>
                <li>
                  <strong>Hooks</strong>
                  <span>Checks the agent cannot skip, like a review before a push.</span>
                </li>
              </ul>
              <p className="credit">
                Named works are credited as sources, not as endorsements. Other rubrics, such as{" "}
                <code>cf:docker</code>, are this project's own house rules.
              </p>
            </div>
          </div>

          <h3 className="home-sub" id="map-title">Everything it installs</h3>
          <div className="toolkit-map" aria-labelledby="map-title">
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

        <section className="home-section" id="before-it-merges" aria-labelledby="gate-title">
          <h2 id="gate-title">Before it merges</h2>
          <p className="home-text">
            A rubric guides an edit; the gate tests the result. Add one <code>CHANGE.md</code> at the
            repo root that says how to boot your app. Each check runs in its own container against
            the running app, and any failure blocks the merge.
          </p>
          <ul className="gate-lanes">
            {LANES.map((lane) => (
              <Lane key={lane.name} {...lane} />
            ))}
          </ul>
          <div className="gate-example">
            <CodeBlock code={EXAMPLE_CHANGE_MD} label="CHANGE.md" />
          </div>
          <p className="home-text">
            You do not need this on day one. It waits until you're ready to gate.{" "}
            <a href={specPath(CURRENT_VERSION)}>Read the CHANGE.md spec</a>
          </p>
        </section>

        <section className="home-section" id="start-building" aria-labelledby="start-title">
          <h2 id="start-title">Start building</h2>
          <p className="home-text">
            Three commands, then the agent you already use. Your first win comes on the next edit.
          </p>
          <ol className="steps">
            <li>
              <h3>Install</h3>
              <CodeBlock code={INSTALL} label="Terminal" />
              <p className="steps-note">
                No Homebrew? Clone the repo and run <code>ruby install.rb</code>. Needs Ruby 3.2 or
                newer.
              </p>
            </li>
            <li>
              <h3>Open your agent</h3>
              <p>Start a new session in any project. The skills load on their own.</p>
            </li>
            <li>
              <h3>Watch the first rubric apply</h3>
              <p>
                Ask for a small change. On the next edit your agent names the rubric it is following,
                for example <code>cf:refactoring</code>, and explains the change in its terms.
              </p>
            </li>
          </ol>
        </section>
      </div>
    </Layout>
  );
}
