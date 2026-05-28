// Reads the per-user, git-ignored plans.config.json (at the skill root, one
// level above studio/). Absent config → sensible local-only defaults. Runs at
// dev/build time in node; the resolved values are baked into pages.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface SiteConfig {
  /** Public host for published artifacts, e.g. artifacts.pstaylor.net. */
  domain?: string;
  /** Lambda Function URL for the opt-in view counter (from terraform output). */
  analyticsEndpoint?: string;
  /** Force noindex/nofollow. Default true - these are private artifacts. */
  noindex?: boolean;
}

const DEFAULTS: SiteConfig = { noindex: true };

export function siteConfig(): SiteConfig {
  const candidates = [
    join(process.cwd(), "plans.config.json"),
    join(process.cwd(), "..", "plans.config.json"),
  ];
  for (const p of candidates) {
    try {
      if (existsSync(p)) {
        return { ...DEFAULTS, ...JSON.parse(readFileSync(p, "utf8")) };
      }
    } catch {
      /* fall through to defaults */
    }
  }
  return DEFAULTS;
}
