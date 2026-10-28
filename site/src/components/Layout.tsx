import type { ReactNode } from "react";
import { GithubLogo, MoonIcon, SunIcon } from "../icons";
import { useTheme } from "../theme";
import { CURRENT_VERSION, specPath } from "../spec";
import { LockupHorizontal } from "./Logo";

const REPO_URL = "https://github.com/change-fabric/change-fabric";

// The primary sections. `match` marks a link current for every path under it,
// so a skill detail page still highlights Reference.
const PRIMARY = [
  { label: "Spec", href: specPath(CURRENT_VERSION), match: "/spec" },
  { label: "Changelog", href: "/changelog", match: "/changelog" },
  { label: "Reference", href: "/reference", match: "/reference" },
];

// Sibling projects, listed under their own heading so they do not read as
// parts of the spec.
const RELATED = [
  { label: "Moose", href: "/moose", match: "/moose" },
  { label: "Porcupine", href: "/porcupine", match: "/porcupine" },
];

function NavLink({ link }: { link: (typeof PRIMARY)[number] }) {
  return (
    <a
      className="nav-link"
      href={link.href}
      aria-current={isCurrent(link.match) ? "page" : undefined}
    >
      {link.label}
    </a>
  );
}

function isCurrent(match: string): boolean {
  const path = window.location.pathname;
  return path === match || path.startsWith(`${match}/`);
}

function ThemeToggle() {
  const { theme, toggle } = useTheme();
  const next = theme === "dark" ? "light" : "dark";
  return (
    <button
      type="button"
      className="icon-btn"
      onClick={toggle}
      aria-label={`Switch to ${next} theme`}
      title={`Switch to ${next} theme`}
    >
      {theme === "dark" ? <SunIcon size={18} /> : <MoonIcon size={18} />}
    </button>
  );
}

// A left sidebar from 960px up, a top bar below it; the markup is the same and
// styles.css does the switch.
export function Layout({ children }: { children: ReactNode }) {
  return (
    <div className="shell">
      <header className="site-header">
        <a className="wordmark" href="/" aria-label="change fabric, home">
          <LockupHorizontal />
        </a>
        <nav className="site-nav" aria-label="Primary">
          {PRIMARY.map((link) => (
            <NavLink key={link.label} link={link} />
          ))}
          <span className="nav-group-label">Related projects</span>
          {RELATED.map((link) => (
            <NavLink key={link.label} link={link} />
          ))}
        </nav>
        <div className="site-utils">
          <a
            className="icon-btn"
            href={REPO_URL}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="GitHub repository"
            title="GitHub repository"
          >
            <GithubLogo size={18} />
          </a>
          <ThemeToggle />
        </div>
      </header>

      <div className="page">
        <main>{children}</main>

        {/* Below 960px the header carries Spec, Changelog, Reference and the related projects,
            the wordmark is Home and the Spec page links Versions, so the footer
            drops to one quiet row; the full list returns beside the sidebar. */}
        <footer className="site-footer">
          <span className="footer-brand">&copy; Change Fabric</span>
          <nav className="footer-nav" aria-label="Footer">
            <a className="footer-wide" href="/">Home</a>
            <a className="footer-wide" href={specPath(CURRENT_VERSION)}>Spec</a>
            <a className="footer-wide" href="/spec">Versions</a>
            <a className="footer-wide" href="/changelog">Changelog</a>
            <a href="/reference">Reference</a>
            <a className="footer-wide" href="/moose">Moose</a>
            <a className="footer-wide" href="/porcupine">Porcupine</a>
            <a href={REPO_URL} target="_blank" rel="noopener noreferrer">
              GitHub<span aria-hidden="true"> &#8599;</span>
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          </nav>
        </footer>
      </div>
    </div>
  );
}
