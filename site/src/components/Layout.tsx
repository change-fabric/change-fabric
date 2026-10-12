import type { ReactNode } from "react";
import { GithubLogo, MoonIcon, SunIcon } from "../icons";
import { useTheme } from "../theme";
import { CURRENT_VERSION, specPath } from "../spec";

const REPO_URL = "https://github.com/change-fabric/change-fabric";

// The primary sections. `match` marks a link current for every path under it,
// so a skill detail page still highlights Reference.
const PRIMARY = [
  { label: "Spec", href: specPath(CURRENT_VERSION), match: "/spec" },
  { label: "Changelog", href: "/changelog", match: "/changelog" },
  { label: "Reference", href: "/reference", match: "/reference" },
];

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
        <a className="wordmark" href="/">
          change fabric
        </a>
        <nav className="site-nav" aria-label="Primary">
          {PRIMARY.map((link) => (
            <a
              key={link.label}
              className="nav-link"
              href={link.href}
              aria-current={isCurrent(link.match) ? "page" : undefined}
            >
              {link.label}
            </a>
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

        <footer className="site-footer">
          <nav className="footer-nav" aria-label="Footer">
            <a href="/">Home</a>
            <a href={specPath(CURRENT_VERSION)}>Spec</a>
            <a href="/spec">Versions</a>
            <a href="/changelog">Changelog</a>
            <a href="/reference">Reference</a>
            <a href={REPO_URL} target="_blank" rel="noopener noreferrer">
              GitHub
            </a>
          </nav>
        </footer>
      </div>
    </div>
  );
}
