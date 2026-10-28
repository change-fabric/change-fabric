import type { ReactNode } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { Mark } from "../components/Logo";

const PORCUPINE_REPO_URL = "https://github.com/change-fabric/porcupine";
const README_URL = `${PORCUPINE_REPO_URL}#readme`;
const SECURITY_URL = `${PORCUPINE_REPO_URL}/blob/main/SECURITY.md`;
const CADDYFILE_URL = `${PORCUPINE_REPO_URL}/blob/main/examples/Caddyfile`;

// Real captures of the app: phone frames from a throwaway demo session, the
// desktop settings and usage stills from a recording of the desktop layout.
const SHOTS = "/porcupine";

// What you do with a running session, each beside a phone capture of it.
const CONTROLS = [
  {
    n: "01",
    name: "Watch",
    detail: "Follow a session's tool calls and output as they stream, from anywhere on your network.",
    src: `${SHOTS}/watch.webp`,
    alt: "A porcupine session on a phone mid-run: an ask_user_question step, then bash and read tool calls, two still running.",
  },
  {
    n: "02",
    name: "Steer",
    detail: "Answer the agent's questions when it asks, send follow-ups, attach files and switch models.",
    src: `${SHOTS}/steer.webp`,
    alt: "porcupine on a phone: the agent asks whether the new tests should use node:test or vitest, with node:test selected and Submit ready.",
  },
  {
    n: "03",
    name: "Stop",
    detail: "The send button becomes a stop button while the agent works. Tap it and the run ends where it is, marked aborted.",
    src: `${SHOTS}/stop.webp`,
    alt: "porcupine on a phone right after stopping a run: the last tool calls, an aborted marker and the composer ready again.",
    height: 354,
  },
];

// Required on the host, then the two pieces you choose yourself.
const TOOLS = [
  {
    group: "Required",
    marks: [
      { id: "nodedotjs", name: "Node.js" },
      { id: "tmux", name: "tmux" },
      { id: "ruby", name: "Ruby" },
      { id: "pi", name: "pi" },
      { id: "openrouter", name: "OpenRouter" },
    ],
  },
  {
    group: "Private network, or a LAN",
    marks: [
      { id: "tailscale", name: "Tailscale" },
      { id: "wireguard", name: "WireGuard" },
    ],
  },
  { group: "HTTPS proxy, or similar", marks: [{ id: "caddy", name: "Caddy" }] },
];

// Usage and budgets is the featured item; the other two support it.
const FEATURES = [
  {
    name: "Attachments",
    detail:
      "Images, PDFs, audio and video. Audio and video are transcribed on the host by whisper.cpp, and costly attachments ask before spending.",
    href: `${PORCUPINE_REPO_URL}#attachments`,
    cta: "Supported attachment types",
  },
  {
    name: "Loops, subagents and plan mode",
    detail: "/loop repeats a prompt, subagents run tasks in separate pi processes, and /plan keeps edits off until you approve a plan.",
    href: `${PORCUPINE_REPO_URL}#loops`,
    cta: "Loops and subagents",
  },
];

const PREREQS = ["Node 22+", "tmux", "Ruby", "OpenRouter API key", "A private network", "HTTPS in front of the hub"];

// The README's install steps, split so no line runs long. The backslashes
// keep the && chain, so the commands behave exactly as the README's.
const CLONE = `git clone https://github.com/change-fabric/porcupine.git
cd porcupine
`;

const CONFIGURE = `mkdir -p ~/.config/porcupine && \\
  cp .env.example ~/.config/porcupine/.env && \\
  chmod 600 ~/.config/porcupine/.env
$EDITOR ~/.config/porcupine/.env
`;

const INSTALL = `ruby install.rb
`;

const RUN = `tmux new-session -d -s porcupine-hub \\
  porcupine-hub
tmux new-session -s myrepo -c ~/code/myrepo \\
  'porcupine --name myrepo'
`;

// The cf bridge, as the porcupine README describes it.
const BRIDGE = [
  {
    n: "01",
    name: "Hooks",
    detail: "Runs the hooks in ~/.claude/settings.json with Claude Code semantics, so PreToolUse can block a tool call or ask you in the app.",
  },
  { n: "02", name: "Merge mode", detail: "The session sheet reads and sets the session's cf merge mode through cf's own scripts." },
  { n: "03", name: "Skills", detail: "Every ~/.claude/skills/<name>/SKILL.md, cf's included, becomes a /<name> command." },
];

function External({ href, children, className }: { href: string; children: ReactNode; className?: string }) {
  return (
    <a className={className} href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}

function TechMark({ id, name }: { id: string; name: string }) {
  return <span className={`tech-mark tech-${id}`} role="img" aria-label={name} />;
}

// Small frames hold the user's iPhone recording, which is only 296px wide.
function Phone({
  src,
  alt,
  eager,
  small,
  height,
}: {
  src: string;
  alt: string;
  eager?: boolean;
  small?: boolean;
  height?: number;
}) {
  return (
    <div className={small ? "porcupine-phone porcupine-phone-small" : "porcupine-phone"}>
      <img
        src={src}
        width={small ? 296 : 390}
        height={height ?? (small ? 510 : 844)}
        alt={alt}
        loading={eager ? "eager" : "lazy"}
        decoding="async"
      />
    </div>
  );
}

export function Porcupine() {
  return (
    <Layout>
      <div className="home project porcupine">
        <section className="hero project-hero porcupine-hero" aria-labelledby="porcupine-title">
          <div className="porcupine-hero-text">
            <p className="hero-eyebrow">
              Related project / Open source <span className="status-tag">Pre-alpha</span>
            </p>
            <img className="porcupine-hero-logo" src="/brand/porcupine.png" width="56" height="56" alt="porcupine logo" />
            <h1 id="porcupine-title">
              Your agents run at home. <span className="project-h1-line">You drive from your phone.</span>
            </h1>
            <p className="hero-copy">
              porcupine is a small, mobile-first PWA for pi coding-agent sessions. Sessions run in tmux on a
              machine you own; from a phone or laptop browser you watch them stream, send prompts, switch
              models, answer the agent's questions and stop runs.
            </p>
            <p className="project-meta">MIT licensed · Self-hosted hub · Your own model providers</p>
            <div className="hero-actions">
              <a className="btn" href="#get-started">
                Get started <span aria-hidden="true">&rarr;</span>
              </a>
              <External className="btn btn-quiet" href={PORCUPINE_REPO_URL}>
                View on GitHub
              </External>
            </div>
          </div>
          <Phone
            src={`${SHOTS}/hero-session.webp`}
            alt="porcupine on a phone in dark mode: the session header, the latest bash and read tool calls of a running session, and the composer with its stop button."
            height={549}
            eager
          />
        </section>

        <section className="porcupine-tools" aria-labelledby="porcupine-tools-title">
          <h2 id="porcupine-tools-title" className="porcupine-tools-title">Built with familiar tools</h2>
          <div className="porcupine-tool-groups">
            {TOOLS.map((g) => (
              <div key={g.group} className="porcupine-tool-group">
                <p className="porcupine-tool-label">{g.group}</p>
                <ul>
                  {g.marks.map((m) => (
                    <li key={m.id}>
                      <TechMark {...m} />
                      <span>{m.name}</span>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </section>

        <section className="home-section" aria-labelledby="porcupine-controls-title">
          <h2 id="porcupine-controls-title">Watch. Steer. Stop.</h2>
          <ol className="porcupine-shots">
            {CONTROLS.map((c) => (
              <li key={c.name}>
                <Phone src={c.src} alt={c.alt} height={c.height} />
                <div>
                  <span className="lane-n" aria-hidden="true">{c.n}</span>
                  <h3>{c.name}</h3>
                  <p>{c.detail}</p>
                </div>
              </li>
            ))}
          </ol>
        </section>

        <section className="home-section" aria-labelledby="porcupine-arch-title">
          <h2 id="porcupine-arch-title">Your sessions stay on your host.</h2>
          <p className="home-lede">
            Your browser reaches the host over HTTPS on a private network. A reverse proxy terminates TLS
            in front of porcupine-hub, which serves the app, checks the password and relays each browser
            to a session over a local Unix socket. Each session wraps pi in a tmux pane.
          </p>
          <div className="porcupine-net" role="group" aria-label="How a request flows">
            <p className="project-region-label">
              <TechMark id="tailscale" name="Tailscale" /> Your private network
            </p>
            <div className="project-node">
              <span className="project-node-title">Phone or laptop</span>
              <span className="project-node-sub">Any modern browser, installable as a PWA</span>
            </div>
            <p className="project-link">
              <span className="project-link-label">HTTPS</span>
              <span className="project-link-arrow porcupine-req" aria-hidden="true" />
            </p>
            <div className="porcupine-host">
              <p className="porcupine-host-label">Your host</p>
              <div className="project-node">
                <span className="project-node-title">Reverse proxy</span>
                <span className="project-node-sub">Caddy or similar, terminates TLS</span>
              </div>
              <p className="project-link">
                <span className="project-link-label">HTTP</span>
                <span className="project-link-arrow porcupine-req" aria-hidden="true" />
              </p>
              <div className="project-hub">
                <img src="/brand/porcupine.png" width="56" height="56" alt="" />
                <span className="project-hub-title">porcupine-hub</span>
                <span className="project-hub-sub">Serves the app, relays sessions</span>
              </div>
              <p className="project-link">
                <span className="project-link-label">Unix socket</span>
                <span className="project-link-arrow porcupine-req" aria-hidden="true" />
              </p>
              <div className="project-node">
                <span className="project-node-title">porcupine in tmux</span>
                <span className="project-marks">
                  <TechMark id="pi" name="pi" />
                </span>
                <span className="project-node-sub">Wraps pi --mode rpc</span>
              </div>
            </div>
          </div>
          <p className="home-note porcupine-net-note">
            Arrows show the request path; responses and streamed output return the same way. The hub is self-hosted. Two things leave the host: model calls to your providers (OpenRouter,
            plus Anthropic and OpenAI if you add their keys) and Web Push notifications, which go through
            your browser's push service.
          </p>
          <div className="porcupine-devices">
            <figure className="porcupine-laptop">
              <img
                src={`${SHOTS}/desktop-settings.webp`}
                width="1040"
                height="638"
                loading="lazy"
                decoding="async"
                alt="porcupine session settings in a laptop browser: New conversation, Compact now, context, auto-compact and thinking level beside the model picker."
              />
              <figcaption>Session settings in a laptop browser.</figcaption>
            </figure>
            <figure className="porcupine-iphone">
              <Phone small src={`${SHOTS}/iphone-sessions.webp`} alt="The porcupine sessions drawer on an iPhone, listing porcupine, moose and two demo sessions." />
              <figcaption>The sessions drawer on an iPhone.</figcaption>
            </figure>
          </div>
        </section>

        <section className="home-section" aria-labelledby="porcupine-features-title">
          <h2 id="porcupine-features-title">Built for long runs.</h2>
          <div className="porcupine-lead">
            <span className="lane-n" aria-hidden="true">Notifications</span>
            <h3>Stay connected to long runs.</h3>
            <p>
              The sessions list marks each one as running, unread when it finished while you were away, or
              waiting for input when the agent asks a question or a hook wants confirmation. Turn on Web Push
              and your phone tells you when a run finishes or needs you, and tapping the notification opens
              that session.
            </p>
            <External href={`${PORCUPINE_REPO_URL}#notifications-and-background-agents`}>
              How notifications work <span aria-hidden="true">&rarr;</span>
            </External>
          </div>
          <div className="porcupine-featured">
            <div className="porcupine-featured-text">
              <h3>Usage and budgets</h3>
              <p>
                Every model response is recorded with its tokens and cost. Settings shows this month's spend
                per provider and model with a daily chart, and budgets warn at 80% and 100% without ever
                blocking a prompt.
              </p>
              <External href={`${PORCUPINE_REPO_URL}#usage-and-budgets`}>
                How usage is tracked <span aria-hidden="true">&rarr;</span>
              </External>
            </div>
            <figure className="porcupine-featured-media">
              <figcaption>Settings, Usage: a laptop in light mode and an iPhone in dark mode.</figcaption>
              <div>
                <img
                  className="porcupine-feature-img"
                  src={`${SHOTS}/usage.webp`}
                  width="900"
                  height="666"
                  loading="lazy"
                  decoding="async"
                  alt="porcupine Settings, Usage tab: spend this month per provider with per-model rows and a daily chart."
                />
                <Phone small src={`${SHOTS}/iphone-usage-dark.webp`} alt="porcupine Settings in dark mode on an iPhone, with this month's usage." />
              </div>
            </figure>
          </div>
          <ul className="porcupine-features">
            {FEATURES.map((f) => (
              <li key={f.name}>
                <h3>{f.name}</h3>
                <p>{f.detail}</p>
                <External href={f.href}>
                  {f.cta} <span aria-hidden="true">&rarr;</span>
                </External>
              </li>
            ))}
          </ul>
        </section>

        <section className="home-section" id="get-started" aria-labelledby="porcupine-start-title">
          <h2 id="porcupine-start-title">Get up and running.</h2>
          <div className="porcupine-prereqs">
            <p className="porcupine-tool-label">You need</p>
            <ul>
              {PREREQS.map((p) => (
                <li key={p}>
                  <span className="porcupine-check" aria-hidden="true">&#10003;</span>
                  {p}
                </li>
              ))}
            </ul>
          </div>
          <aside className="porcupine-security" aria-label="Security note">
            <p className="porcupine-security-label">Security note</p>
            <p>
              Whoever logs in can run shell commands on the host through the agent. Keep the hub on a private
              network and read <External href={SECURITY_URL}>SECURITY.md</External> before exposing it anywhere.
            </p>
          </aside>
          <ol className="project-steps">
            <li>
              <h3>Get the code</h3>
              <div className="project-code">
                <CodeBlock code={CLONE} label="clone" />
              </div>
            </li>
            <li>
              <h3>Configure</h3>
              <p>
                Set <code>PORCUPINE_ORIGIN</code>, the password, the cookie secret and{" "}
                <code>OPENROUTER_API_KEY</code> in <code>.env</code>.
              </p>
              <div className="project-code">
                <CodeBlock code={CONFIGURE} label="configure" />
              </div>
            </li>
            <li>
              <h3>Install</h3>
              <p>
                Checks prerequisites, builds, installs the pinned pi and links <code>porcupine</code> and{" "}
                <code>porcupine-hub</code> into <code>~/.local/bin</code>. porcupine is pre-alpha: rerun it
                after each pull.
              </p>
              <div className="project-code">
                <CodeBlock code={INSTALL} label="install" />
              </div>
            </li>
            <li>
              <h3>Start the hub and a session</h3>
              <p>The hub runs once in its own tmux session; start a named session in any repo.</p>
              <div className="project-code">
                <CodeBlock code={RUN} label="start" />
              </div>
            </li>
          </ol>
          <p className="home-note">
            Then put HTTPS in front of the hub (the repo ships a{" "}
            <External href={CADDYFILE_URL}>Caddyfile example</External>) and follow the{" "}
            <External href={README_URL}>setup guide</External>.
          </p>
        </section>

        <section className="home-section" aria-labelledby="porcupine-cf-title">
          <h2 id="porcupine-cf-title">Works with Change Fabric.</h2>
          <p className="home-lede">If you use Change Fabric, every porcupine session runs its hooks, merge mode and skills.</p>
          <ul className="project-cards">
            {BRIDGE.map((b) => (
              <li key={b.name}>
                <span className="lane-n" aria-hidden="true">{b.n}</span>
                <h3>{b.name}</h3>
                <p>{b.detail}</p>
              </li>
            ))}
          </ul>
          <p className="home-note porcupine-trust">
            porcupine has no permission system of its own, so your hooks decide what a tool call may do;
            Change Fabric is not required.{" "}
            <External href={`${PORCUPINE_REPO_URL}#change-fabric-cf-bridge`}>How the cf bridge works</External>
          </p>
          <div className="project-family">
            <div>
              <p className="home-lede">
                porcupine is a separate, MIT-licensed project, not part of the Change Fabric spec. It focuses
                on driving coding-agent sessions from your phone; Change Fabric focuses on software quality
                and release readiness.
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
