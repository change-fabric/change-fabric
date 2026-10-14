import { useEffect, useMemo, useRef, useState } from "react";
import { Layout } from "../components/Layout";
import { MagnifyingGlassIcon, XIcon } from "../icons";
import { SourceLink } from "../components/SourceLink";
import { HOOKS, SKILLS, SKILLS_SOURCE_URL, hookPath, skillPath } from "../reference";
import type { Group } from "../reference";
import { createSearch } from "../search";

interface Item {
  key: string;
  group: Group;
  name: string;
  summary: string;
  description: string;
  href: string;
}

// `kind` is the singular label a row carries in the flat (filtered) list,
// where no group heading says what each row is.
const GROUPS: { id: Group; label: string; kind: string }[] = [
  { id: "lanes", label: "Lanes", kind: "Lane" },
  { id: "rubrics", label: "Rubrics", kind: "Rubric" },
  { id: "workflow", label: "Workflow", kind: "Workflow" },
  { id: "modes", label: "Modes", kind: "Mode" },
  { id: "hooks", label: "Hooks", kind: "Hook" },
];

const ITEMS: Item[] = [
  ...SKILLS.map((skill) => ({
    key: `skill:${skill.id}`,
    group: skill.group,
    name: skill.name,
    summary: skill.summary,
    description: skill.description,
    href: skillPath(skill.id),
  })),
  ...HOOKS.map((hook) => ({
    key: `hook:${hook.id}`,
    group: "hooks" as Group,
    name: hook.script,
    summary: hook.summary,
    description: hook.description,
    href: hookPath(hook.id),
  })),
];

const score = createSearch(ITEMS);

function readUrl(): { query: string; group: Group | "all" } {
  const params = new URLSearchParams(window.location.search);
  const group = params.get("group");
  return {
    query: params.get("q") ?? "",
    group: GROUPS.some((entry) => entry.id === group) ? (group as Group) : "all",
  };
}

function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName);
}

export function Reference() {
  const initial = useMemo(readUrl, []);
  const [query, setQuery] = useState(initial.query);
  const [group, setGroup] = useState<Group | "all">(initial.group);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return;
      if (isTypingTarget(event.target)) return;
      event.preventDefault();
      inputRef.current?.focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    const params = new URLSearchParams();
    if (query.trim()) params.set("q", query.trim());
    if (group !== "all") params.set("group", group);
    const search = params.toString();
    const url = `${window.location.pathname}${search ? `?${search}` : ""}`;
    window.history.replaceState(null, "", url);
  }, [query, group]);

  const needle = query.trim().toLowerCase();
  const filtering = needle !== "" || group !== "all";
  // Ranked best first while a query is typed; with no query every score is
  // equal and the stable sort keeps the alphabetical order.
  const searched = ITEMS.map((item) => ({ item, score: score(needle, item) }))
    .filter((hit) => hit.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((hit) => hit.item);
  const visible = searched.filter((item) => group === "all" || item.group === group);

  const row = (item: Item) => (
    <li key={item.key} className="ref-row">
      <a href={item.href} className="ref-name">
        {item.name}
      </a>
      <span className="ref-summary" title={item.description}>
        {item.summary}
      </span>
      {filtering && (
        <span className="ref-kind">{GROUPS.find((entry) => entry.id === item.group)!.kind}</span>
      )}
    </li>
  );

  const clear = () => {
    setQuery("");
    inputRef.current?.focus();
  };

  const chips = [{ id: "all" as const, label: "All" }, ...GROUPS].map((chip) => ({
    ...chip,
    count: chip.id === "all" ? searched.length : searched.filter((i) => i.group === chip.id).length,
  }));

  return (
    <Layout>
      <section className="reference-index">
        <header className="page-head">
          <div className="page-head-row reference-head-row">
            <h1>Reference</h1>
            <SourceLink href={SKILLS_SOURCE_URL} label="View on GitHub" title="Skills directory on GitHub" />
          </div>
          <p className="section-lede">Every skill and hook the toolkit installs.</p>
        </header>

        <div className="ref-search">
          <span className="ref-search-icon">
            <MagnifyingGlassIcon />
          </span>
          <label htmlFor="ref-search-input" className="ref-search-label">
            Search skills and hooks
          </label>
          <input
            id="ref-search-input"
            ref={inputRef}
            type="search"
            className="ref-search-input"
            placeholder="Search skills and hooks"
            autoComplete="off"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") setQuery("");
            }}
          />
          <span className="ref-search-end">
            {query ? (
              <button
                type="button"
                className="icon-btn ref-clear"
                onClick={clear}
                aria-label="Clear search"
                title="Clear search (Esc)"
              >
                <XIcon size={14} />
              </button>
            ) : (
              <kbd className="ref-kbd" aria-hidden="true">
                /
              </kbd>
            )}
          </span>
        </div>

        <div className="ref-chips" role="group" aria-label="Filter by group">
          {/* Every group stays listed with its live count, 0 included, so the
              rail never reshuffles under the user while they type. */}
          {chips.map((chip) => (
            <button
              key={chip.id}
              type="button"
              className="ref-chip"
              aria-pressed={group === chip.id}
              onClick={() => setGroup(chip.id)}
            >
              {chip.label} <span className="ref-count">{chip.count}</span>
            </button>
          ))}
        </div>

        <p className="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {visible.length === 0
            ? "Nothing matches that search."
            : `${visible.length} ${visible.length === 1 ? "result" : "results"}`}
        </p>

        <div>
          {visible.length === 0 ? (
            <p className="ref-empty">Nothing matches that search.</p>
          ) : filtering ? (
            <ul className="ref-list ref-list-flat">{visible.map(row)}</ul>
          ) : (
            GROUPS.map((entry) => (
              <section key={entry.id} className="ref-group" aria-labelledby={`ref-h-${entry.id}`}>
                <h2 id={`ref-h-${entry.id}`}>{entry.label}</h2>
                <ul className="ref-list">{visible.filter((i) => i.group === entry.id).map(row)}</ul>
              </section>
            ))
          )}
        </div>
      </section>
    </Layout>
  );
}
