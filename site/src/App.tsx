import { Home } from "./pages/Home";
import { SpecPage } from "./pages/SpecPage";
import { Versions } from "./pages/Versions";

// A tiny path-based router. Navigation is plain full-page anchors, so each load
// resolves the current path here. CloudFront serves index.html for unknown
// paths (its 404 fallback), so /spec and /spec/<version> reach this router. The
// raw /spec/<version>.md is a real static file and never loads the app.
export function App() {
  const path = window.location.pathname.replace(/\/+$/, "") || "/";

  if (path === "/spec") {
    return <Versions />;
  }

  const specMatch = path.match(/^\/spec\/([^/]+)$/);
  if (specMatch) {
    return <SpecPage version={specMatch[1]} />;
  }

  return <Home />;
}
