import type { ReactNode } from "react";
import { MoonIcon, SunIcon } from "../icons";
import { useTheme } from "../theme";
import { navigate } from "../router";

/**
 * The frame every screen sits in. Two shapes, one component: a signed-out shell
 * with no navigation at all, and a signed-in shell carrying the org bar and the
 * app's own links. Splitting them into two components would duplicate the header
 * chrome for the sake of one conditional.
 */

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

export function NavButton({
  to,
  current,
  children,
}: {
  to: string;
  current: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      className="nav-link"
      aria-current={current === to ? "page" : undefined}
      onClick={() => navigate(to)}
    >
      {children}
    </button>
  );
}

export function Shell({
  nav,
  children,
}: {
  nav?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="page">
      <header className="site-header">
        <span className="wordmark">change fabric</span>
        <nav className="site-nav" aria-label="Primary">
          {nav}
          <ThemeToggle />
        </nav>
      </header>

      <main>{children}</main>

      <footer className="site-footer">
        staging environment. Not production data.
      </footer>
    </div>
  );
}
