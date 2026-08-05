import type { ReactNode } from "react";
import { GithubLogo, MoonIcon, SunIcon } from "../icons";
import { useTheme } from "../theme";
import { CURRENT_VERSION, specPath } from "../spec";

const REPO_URL = "https://github.com/change-fabric/change-fabric";

// The platform app's root URL. Its "/" path renders a login screen for an
// unauthenticated visitor (with a link to /signup from there), so a single
// link to the app's origin covers both log in and sign up. Overridable at
// build time for a non-default deploy; defaults to production, which does
// not exist yet as of this link shipping (see platform infrastructure work).
const APP_ORIGIN: string =
  import.meta.env.VITE_APP_ORIGIN ?? "https://app.changefabric.org";

function ThemeToggle() {
  const { theme, toggle } = useTheme();
  const next = theme === "dark" ? "light" : "dark";
  return (
    <button
      type="button"
      className="theme-toggle"
      onClick={toggle}
      aria-label={`Switch to ${next} theme`}
      title={`Switch to ${next} theme`}
    >
      {theme === "dark" ? <SunIcon size={18} /> : <MoonIcon size={18} />}
    </button>
  );
}

export function Layout({ children }: { children: ReactNode }) {
  return (
    <div className="page">
      <header className="site-header">
        <a className="wordmark" href="/">
          change fabric
        </a>
        <nav className="site-nav" aria-label="Primary">
          <a className="nav-link" href={specPath(CURRENT_VERSION)}>
            Spec
          </a>
          <a className="nav-link" href="/reference">
            Reference
          </a>
          <a
            className="nav-link nav-icon"
            href={REPO_URL}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="GitHub repository"
          >
            <GithubLogo size={18} />
          </a>
          <ThemeToggle />
        </nav>
      </header>

      <main>{children}</main>

      <footer className="site-footer">
        <nav className="footer-nav" aria-label="Footer">
          <a href="/">Home</a>
          <a href={specPath(CURRENT_VERSION)}>Spec</a>
          <a href="/spec">Versions</a>
          <a href="/reference">Reference</a>
          <a href={REPO_URL} target="_blank" rel="noopener noreferrer">
            GitHub
          </a>
          <a href={APP_ORIGIN}>Log In / Sign Up</a>
        </nav>
      </footer>
    </div>
  );
}
