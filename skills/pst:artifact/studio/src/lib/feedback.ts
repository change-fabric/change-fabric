/**
 * On-disk feedback store. The comment island (dev only) POSTs threads here via
 * src/middleware.ts; they land in studio/feedback/<id>.json. `/pst:artifact
 * --feedback <id>` reads that file back to revise the plan - a real round-trip,
 * not a clipboard paste. The published static bundle never touches this.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";

/** A single captured comment, Figma/Vercel-preview style. */
export interface Thread {
  id: string;
  /** Document-absolute pin coordinates (px). */
  x: number;
  y: number;
  /** Nearest [data-anchor] label, for grounding the feedback semantically. */
  anchor: string | null;
  /** Nearest section heading text. */
  section: string | null;
  /** CSS selector path of the clicked element (re-anchoring hint). */
  selector: string | null;
  /** Text content near the click (trimmed), so Claude has local context. */
  snippet: string | null;
  /** Viewport width when captured (px coords are reflow-sensitive). */
  viewport: number | null;
  /** The reviewer's comment. */
  comment: string;
  status: "open" | "resolved";
  createdAt: string;
}

const FEEDBACK_DIR = join(process.cwd(), "feedback");

function pathFor(id: string): string {
  // Defensive: ids are short base62, but never let one escape the dir.
  const safe = id.replace(/[^A-Za-z0-9_-]/g, "");
  return join(FEEDBACK_DIR, `${safe}.json`);
}

export function loadThreads(id: string): Thread[] {
  try {
    const raw = JSON.parse(readFileSync(pathFor(id), "utf8"));
    return Array.isArray(raw?.threads) ? (raw.threads as Thread[]) : [];
  } catch {
    return [];
  }
}

export function saveThreads(id: string, threads: Thread[]): void {
  if (!existsSync(FEEDBACK_DIR)) mkdirSync(FEEDBACK_DIR, { recursive: true });
  const payload = {
    id,
    updatedAt: new Date().toISOString(),
    threads,
  };
  writeFileSync(pathFor(id), JSON.stringify(payload, null, 2) + "\n", "utf8");
}

/** ids that currently have any saved feedback (for the gallery badge). */
export function plansWithFeedback(): Set<string> {
  try {
    return new Set(
      readdirSync(FEEDBACK_DIR)
        .filter((f) => f.endsWith(".json"))
        .map((f) => f.replace(/\.json$/, "")),
    );
  } catch {
    return new Set();
  }
}
