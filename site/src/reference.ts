import skillsJson from "./generated/reference/skills.json";
import hooksJson from "./generated/reference/hooks.json";

// Embedded at build time by scripts/embed-reference.mjs, straight from the
// repo's own skills/*/SKILL.md files and install.rb's Installer::HOOKS map -
// the same source the installer itself reads, so this page can't describe a
// skill or hook that doesn't actually exist.

export type SkillGroup = "lanes" | "rubrics" | "modes" | "workflow";
export type Group = SkillGroup | "hooks";

export interface SkillReference {
  id: string;
  name: string;
  group: SkillGroup;
  description: string;
  summary: string;
  autoBasenames: string[];
  body: string;
}

export interface HookReference {
  id: string;
  script: string;
  events: string[];
  description: string;
  summary: string;
}

export const SKILLS = skillsJson as SkillReference[];
export const HOOKS: HookReference[] = hooksJson;

export function findSkill(id: string): SkillReference | undefined {
  return SKILLS.find((skill) => skill.id === id);
}

export function findHook(id: string): HookReference | undefined {
  return HOOKS.find((hook) => hook.id === id);
}

export function skillPath(id: string): string {
  return `/reference/skills/${id}`;
}

export function hookPath(id: string): string {
  return `/reference/hooks/${id}`;
}
