import { useEffect, useMemo, useRef, useState } from "react";
import type { ComponentType } from "react";
import { Layout } from "../components/Layout";
import { FlaskIcon, GitBranchIcon, ScalesIcon, SlidersIcon, WebhooksIcon } from "../icons";
import { HOOKS, SKILLS, hookPath, skillPath } from "../reference";
import type { Group } from "../reference";

interface Item {
  key: string;
  group: Group;
  name: string;
  summary: string;
  description: string;
  href: string;
}

const GROUPS: { id: Group; label: string; icon: ComponentType<{ size?: number }> }[] = [
  { id: "lanes", label: "Lanes", icon: FlaskIcon },
  { id: "rubrics", label: "Rubrics", icon: ScalesIcon },
  { id: "workflow", label: "Workflow", icon: GitBranchIcon },
  { id: "modes", label: "Modes", icon: SlidersIcon },
  { id: "hooks", label: "Hooks", icon: WebhooksIcon },
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
  const matches = (item: Item) =>
    (group === "all" || item.group === group) &&
    (needle === "" ||
      item.name.toLowerCase().includes(needle) ||
      item.description.toLowerCase().includes(needle));
  const visible = ITEMS.filter(matches);

  const row = (item: Item) => {
    const Icon = GROUPS.find((entry) => entry.id === item.group)!.icon;
    return (
      <li key={item.key} className="ref-row">
        <span className="ref-icon">
          <Icon />
        </span>
        <a href={item.href} title={item.description} className="ref-name">
          <code>{item.name}</code>
        </a>
        <span className="ref-summary" title={item.description}>
          {item.summary}
        </span>
      </li>
    );
  };

  return (
    <Layout>
      <section className="reference-index">
        <h1>Reference</h1>

        <div className="ref-search">
          <label htmlFor="ref-search-input" className="ref-search-label">
            Search skills and hooks
          </label>
          <input
            id="ref-search-input"
            ref={inputRef}
            type="search"
            className="ref-search-input"
            placeholder="Search (press / to focus)"
            autoComplete="off"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") setQuery("");
            }}
          />
        </div>

        <div className="ref-chips" role="group" aria-label="Filter by group">
          {[{ id: "all" as const, label: "All" }, ...GROUPS].map((chip) => {
            const count =
              chip.id === "all" ? ITEMS.length : ITEMS.filter((i) => i.group === chip.id).length;
            return (
              <button
                key={chip.id}
                type="button"
                className="ref-chip"
                aria-pressed={group === chip.id}
                onClick={() => setGroup(chip.id)}
              >
                {chip.label} <span className="ref-count">{count}</span>
              </button>
            );
          })}
        </div>

        <div aria-live="polite">
          {visible.length === 0 ? (
            <p className="ref-empty">Nothing matches that search.</p>
          ) : filtering ? (
            <ul className="ref-list">{visible.map(row)}</ul>
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
