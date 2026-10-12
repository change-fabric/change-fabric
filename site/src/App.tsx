import { Home } from "./pages/Home";
import { SpecPage } from "./pages/SpecPage";
import { Versions } from "./pages/Versions";
import { Changelog } from "./pages/Changelog";
import { Reference } from "./pages/Reference";
import { ReferenceSkillPage } from "./pages/ReferenceSkillPage";
import { ReferenceHookPage } from "./pages/ReferenceHookPage";
import { Recipes } from "./pages/Recipes";
import { RecipePage } from "./pages/RecipePage";

// A tiny path-based router. Navigation is plain full-page anchors, so each load
// resolves the current path here. CloudFront serves index.html for unknown
// paths (its 404 fallback), so /spec, /spec/<version>, /changelog, /reference,
// /reference/{skills,hooks}/<id>, /recipes, and /recipes/<slug> all reach this router. The raw
// /spec/<version>.md and /changelog.xml are real static files and never load
// the app.
export function App() {
  const path = window.location.pathname.replace(/\/+$/, "") || "/";

  if (path === "/spec") {
    return <Versions />;
  }

  if (path === "/changelog") {
    return <Changelog />;
  }

  const specMatch = path.match(/^\/spec\/([^/]+)$/);
  if (specMatch) {
    return <SpecPage version={specMatch[1]} />;
  }

  if (path === "/reference") {
    return <Reference />;
  }

  const skillMatch = path.match(/^\/reference\/skills\/([^/]+)$/);
  if (skillMatch) {
    return <ReferenceSkillPage id={skillMatch[1]} />;
  }

  const hookMatch = path.match(/^\/reference\/hooks\/([^/]+)$/);
  if (hookMatch) {
    return <ReferenceHookPage id={hookMatch[1]} />;
  }

  if (path === "/recipes") {
    return <Recipes />;
  }

  const recipeMatch = path.match(/^\/recipes\/([a-z0-9-]+)$/);
  if (recipeMatch) {
    return <RecipePage slug={recipeMatch[1]} />;
  }

  return <Home />;
}
