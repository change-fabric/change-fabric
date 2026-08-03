import { useEffect, useState } from "react";

// Light/dark theming. The default follows the OS via prefers-color-scheme; a
// manual toggle overrides it and persists in localStorage so the choice
// survives a reload. Until the user toggles, no data-theme attribute is set, so
// the CSS media query stays in charge and live system changes are followed.
// Once toggled, data-theme on <html> pins the choice and the CSS explicit
// overrides win. An inline script in index.html applies a stored choice before
// first paint to avoid a flash of the wrong theme.

export type Theme = "light" | "dark";

export const THEME_STORAGE_KEY = "cf-theme";

function storedTheme(): Theme | null {
  try {
    const value = localStorage.getItem(THEME_STORAGE_KEY);
    return value === "light" || value === "dark" ? value : null;
  } catch {
    return null;
  }
}

function systemTheme(): Theme {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function useTheme() {
  const [explicit, setExplicit] = useState<boolean>(() => storedTheme() !== null);
  const [theme, setTheme] = useState<Theme>(() => storedTheme() ?? systemTheme());

  useEffect(() => {
    const root = document.documentElement;
    if (explicit) {
      root.setAttribute("data-theme", theme);
    } else {
      root.removeAttribute("data-theme");
    }
  }, [theme, explicit]);

  // Follow the OS live only while the user has made no explicit choice.
  useEffect(() => {
    if (explicit) {
      return;
    }
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setTheme(media.matches ? "dark" : "light");
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, [explicit]);

  function toggle() {
    const next: Theme = theme === "dark" ? "light" : "dark";
    setExplicit(true);
    setTheme(next);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch {
      // A blocked localStorage still toggles for the session; persistence is
      // a nice-to-have, not required for the toggle to work.
    }
  }

  return { theme, toggle };
}
