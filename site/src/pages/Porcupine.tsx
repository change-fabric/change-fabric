import type { ReactNode } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { Mark } from "../components/Logo";

const PORCUPINE_REPO_URL = "https://github.com/change-fabric/porcupine";
const README_URL = `${PORCUPINE_REPO_URL}#readme`;
const SECURITY_URL = `${PORCUPINE_REPO_URL}/blob/main/SECURITY.md`;

// What you do with a running session from the browser, numbered like the
// homepage lanes.
const CONTROLS = [
  {
    n: "01",
    name: "Watch",
    detail: "Stream a session's output live, with session states for running, unread and waiting.",
  },
  {
    n: "02",
    name: "Steer",
    detail: "Send prompts, switch models and answer the agent's questions from the browser.",
  },
  {
    n: "03",
    name: "Stop",
    detail: "Stop a run, compact context, or fork, clone and switch history from the session sheet.",
  },
];

// Each feature links to its own section of the porcupine README.
const FEATURES = [
  {
    name: "Attachments",
    detail:
      "Images, PDFs, audio and video. Audio and video are transcribed locally by whisper.cpp; nothing goes to a cloud speech service. Costly attachments ask first.",
    href: `${PORCUPINE_REPO_URL}#attachments`,
  },
  {
    name: "Notifications",
    detail: "Web Push tells you when a session finishes or waits on you.",
    href: `${PORCUPINE_REPO_URL}#notifications-and-background-agents`,
  },
  {
    name: "Usage and budgets",
    detail:
      "Per-provider usage and budgets. OpenRouter is required; Anthropic and OpenAI keys are optional.",
    href: `${PORCUPINE_REPO_URL}#usage-and-budgets`,
  },
  {
    name: "Loops, subagents and plan mode",
    detail:
      "/loop repeats a prompt, subagents run tasks in separate pi processes, /plan mode keeps a todo list.",
    href: `${PORCUPINE_REPO_URL}#loops`,
  },
];

const REQUIREMENTS = [
  {
    name: "Private network",
    marks: [{ id: "tailscale", name: "Tailscale" }],
    detail: "Tailscale, WireGuard or a LAN between the host and your devices.",
    href: `${PORCUPINE_REPO_URL}#requirements`,
    cta: "View requirements",
  },
  {
    name: "HTTPS in front of the hub",
    marks: [],
    detail: "Service workers and Secure cookies need it. The repo ships a Caddyfile example.",
    href: `${PORCUPINE_REPO_URL}/blob/main/examples/Caddyfile`,
    cta: "View the Caddyfile",
  },
];

// The cf bridge, as the porcupine README describes it.
const BRIDGE = [
  {
    n: "01",
    name: "Hooks",
    detail:
      "Runs the hooks in ~/.claude/settings.json with Claude Code semantics, so PreToolUse can block or ask before a tool call.",
  },
  { n: "02", name: "Merge mode", detail: "The session sheet reads and sets the session's cf merge mode." },
  { n: "03", name: "Skills", detail: "Every ~/.claude/skills/<name>/SKILL.md becomes a /<name> command." },
];

// The README's install and run steps, with the clone URL pointed at the
// change-fabric org.
const INSTALL = `git clone https://github.com/change-fabric/porcupine.git
cd porcupine
mkdir -p ~/.config/porcupine && cp .env.example ~/.config/porcupine/.env && chmod 600 ~/.config/porcupine/.env
$EDITOR ~/.config/porcupine/.env
ruby install.rb
`;

const RUN = `tmux new-session -d -s porcupine-hub porcupine-hub
tmux new-session -s myrepo -c ~/code/myrepo 'porcupine --name myrepo'
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

export function Porcupine() {
  return (
    <Layout>
      <div className="home project porcupine">
        <section className="hero project-hero" aria-labelledby="porcupine-title">
          <p className="hero-eyebrow">
            Related project / Open source <span className="status-tag">Pre-alpha</span>
          </p>
          <div className="project-hero-head">
            <img className="project-logo" src="/brand/porcupine.png" width="96" height="96" alt="porcupine logo" />
            <h1 id="porcupine-title">
              Your agents run at home. <span className="project-h1-line">You drive from your phone.</span>
            </h1>
          </div>
          <p className="hero-copy">
            porcupine is a small, mobile-first PWA for pi coding-agent sessions. Sessions run in tmux
            on a machine you own; from a phone or laptop browser you watch them stream, send prompts,
            switch models, answer the agent's questions and stop runs.
          </p>
          <p className="project-meta">MIT licensed · Self-hosted · No cloud component</p>
          <div className="hero-actions">
            <a className="btn" href="#get-started">
              Get started <span aria-hidden="true">&rarr;</span>
            </a>
            <External className="btn btn-quiet" href={PORCUPINE_REPO_URL}>
              View on GitHub
            </External>
          </div>
        </section>

        <section className="home-section" aria-labelledby="porcupine-arch-title">
          <h2 id="porcupine-arch-title">Everything stays on your host.</h2>
          <p className="home-lede">
            Your phone or laptop talks HTTPS to a reverse proxy in front of porcupine-hub. The hub
            serves the app, checks the password and relays each browser to a session over a local
            Unix socket. Each session wraps pi in a tmux pane.
          </p>
          {/* The browser sits outside; the proxy, hub and sessions share the
              host and its private network, in the README's order. */}
          <div className="project-arch" role="group" aria-label="How a request flows">
            <div className="project-node">
              <span className="project-node-title">Phone or laptop</span>
              <span className="project-node-sub">Any modern browser, installable as a PWA</span>
            </div>
            <p className="project-link">
              <span className="project-link-label">HTTPS</span>
              <span className="project-link-arrow" aria-hidden="true" />
            </p>
            <div className="project-region">
              <p className="project-region-label">
                <TechMark id="tailscale" name="Tailscale" /> Your private network
              </p>
              <div className="project-node">
                <span className="project-node-title">Reverse proxy</span>
                <span className="project-node-sub">Caddy or similar, terminates TLS</span>
              </div>
              <p className="project-link">
                <span className="project-link-label" />
                <span className="project-link-arrow" aria-hidden="true" />
              </p>
              <div className="project-hub">
                <img src="/brand/porcupine.png" width="56" height="56" alt="" />
                <span className="project-hub-title">porcupine-hub</span>
                <span className="project-hub-sub">Serves the app, relays sessions</span>
              </div>
              <p className="project-link">
                <span className="project-link-label">Unix socket</span>
                <span className="project-link-arrow" aria-hidden="true" />
              </p>
              <div className="project-node">
                <span className="project-node-title">porcupine in tmux</span>
                <span className="project-marks">
                  <TechMark id="pi" name="Pi" />
                </span>
                <span className="project-node-sub">Wraps pi --mode rpc</span>
              </div>
            </div>
          </div>
          <p className="home-note project-arch-note">Private network only · No cloud component</p>
        </section>

        <section className="home-section" aria-labelledby="porcupine-controls-title">
          <h2 id="porcupine-controls-title">Watch, steer, stop.</h2>
          <ul className="project-cards">
            {CONTROLS.map((c) => (
              <li key={c.name}>
                <span className="lane-n" aria-hidden="true">{c.n}</span>
                <h3>{c.name}</h3>
                <p>{c.detail}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="home-section" aria-labelledby="porcupine-features-title">
          <h2 id="porcupine-features-title">Built for long runs.</h2>
          <ul className="project-deploys porcupine-features">
            {FEATURES.map((f) => (
              <li key={f.name}>
                <h3>{f.name}</h3>
                <p>{f.detail}</p>
                <External href={f.href}>
                  Read more <span aria-hidden="true">&rarr;</span>
                </External>
              </li>
            ))}
          </ul>
        </section>

        <section className="home-section" aria-labelledby="porcupine-reqs-title">
          <h2 id="porcupine-reqs-title">Self-hosted only.</h2>
          <ul className="project-deploys">
            {REQUIREMENTS.map((r) => (
              <li key={r.name}>
                <span className="project-marks">
                  {r.marks.map((m) => (
                    <TechMark key={m.id} {...m} />
                  ))}
                </span>
                <h3>{r.name}</h3>
                <p>{r.detail}</p>
                <External href={r.href}>
                  {r.cta} <span aria-hidden="true">&rarr;</span>
                </External>
              </li>
            ))}
          </ul>
          <p className="home-note">
            Host: Linux or macOS with Node 22+, tmux and Ruby. An OpenRouter API key.
          </p>
        </section>

        <section className="home-section" id="get-started" aria-labelledby="porcupine-start-title">
          <h2 id="porcupine-start-title">Get up and running.</h2>
          <p className="home-note">
            <strong>
              A logged-in user can run shell commands on the host through the agent.
            </strong>{" "}
            Read <External href={SECURITY_URL}>SECURITY.md</External> before exposing porcupine
            anywhere.
          </p>
          <ol className="project-steps">
            <li>
              <h3>Install</h3>
              <p>
                Set <code>PORCUPINE_ORIGIN</code>, the password, the cookie secret and a provider
                key in <code>.env</code>.
              </p>
              <div className="project-code">
                <CodeBlock code={INSTALL} label="install" />
              </div>
            </li>
            <li>
              <h3>Start the hub and a session</h3>
              <p>The hub runs once in its own tmux session; start a named session in any repo.</p>
              <div className="project-code">
                <CodeBlock code={RUN} label="run" />
              </div>
            </li>
          </ol>
          <p className="home-note">
            Then follow the <External href={README_URL}>setup guide</External>.
          </p>
        </section>

        <section className="home-section" aria-labelledby="porcupine-cf-title">
          <h2 id="porcupine-cf-title">Works with Change Fabric.</h2>
          <p className="home-lede">porcupine has no permission system of its own; it runs cf's.</p>
          <ul className="project-cards">
            {BRIDGE.map((b) => (
              <li key={b.name}>
                <span className="lane-n" aria-hidden="true">{b.n}</span>
                <h3>{b.name}</h3>
                <p>{b.detail}</p>
              </li>
            ))}
          </ul>
        </section>

        <aside className="home-section project-roadmap" aria-labelledby="porcupine-roadmap-title">
          <p className="hero-eyebrow">
            <span className="status-tag">In development</span>
          </p>
          <h2 id="porcupine-roadmap-title">Pre-alpha</h2>
          <p className="home-lede">
            porcupine is early. Expect breaking changes between pulls; rerun{" "}
            <code>ruby install.rb</code> after each one.
          </p>
        </aside>

        <section className="home-section" aria-labelledby="porcupine-family-title">
          <h2 id="porcupine-family-title">Independent projects. Shared philosophy.</h2>
          <div className="project-family">
            <div>
              <p className="home-lede">
                porcupine is a separate, MIT-licensed project, not part of the Change Fabric spec.
                It focuses on driving coding-agent sessions from your phone; Change Fabric focuses
                on software quality and release readiness. Both favor local control and
                infrastructure you own.
              </p>
              <ul className="project-links" aria-label="porcupine resources">
                <li>
                  <External href={PORCUPINE_REPO_URL}>GitHub</External>
                </li>
                <li>
                  <External href={README_URL}>Documentation</External>
                </li>
                <li>
                  <External href={`${PORCUPINE_REPO_URL}/blob/main/LICENSE`}>License (MIT)</External>
                </li>
                <li>
                  <a href="/">About Change Fabric <span aria-hidden="true">&rarr;</span></a>
                </li>
              </ul>
            </div>
            <ul className="project-pair">
              <li>
                <img src="/brand/porcupine.png" width="48" height="48" alt="" />
                <span className="project-pair-name">porcupine</span>
                <span className="project-pair-sub">Your agents, your host</span>
              </li>
              <li>
                <Mark size={48} />
                <span className="project-pair-name">change fabric</span>
                <span className="project-pair-sub">Quality before merge</span>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layout>
  );
}
