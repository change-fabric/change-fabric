import { useEffect, useState } from "react";

/**
 * A path router small enough to read in one sitting.
 *
 * site/ navigates with plain anchors and re-reads the path on load, which suits
 * a set of documents. This app cannot: a full page load throws away the
 * in-memory session state and makes every transition a network round trip, so
 * navigation here is `history.pushState` plus a re-render.
 *
 * CloudFront serves index.html for any unknown path (its 403/404 fallback), so a
 * reload or a pasted deep link still reaches this router.
 */

const PATH_CHANGE = "cf-path-change";

export function navigate(path: string): void {
  if (path === window.location.pathname) {
    return;
  }
  window.history.pushState(null, "", path);
  window.dispatchEvent(new Event(PATH_CHANGE));
}

function currentPath(): string {
  return window.location.pathname.replace(/\/+$/, "") || "/";
}

export function usePath(): string {
  const [path, setPath] = useState(currentPath);

  useEffect(() => {
    const sync = () => setPath(currentPath());
    // popstate covers the back button; the custom event covers our own pushes,
    // which popstate deliberately does not fire for.
    window.addEventListener("popstate", sync);
    window.addEventListener(PATH_CHANGE, sync);
    return () => {
      window.removeEventListener("popstate", sync);
      window.removeEventListener(PATH_CHANGE, sync);
    };
  }, []);

  return path;
}
