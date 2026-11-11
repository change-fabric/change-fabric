// Which published media slot a reference skill page shows, by skill id. A
// slot with no manifest entry renders nothing, so listing one early is safe.
export const SKILL_MEDIA_SLOTS: Readonly<Record<string, string>> = {
  walkthrough: "walkthrough-self",
  narrate: "narrate-sample",
};

export function skillMediaSlot(id: string): string | undefined {
  return Object.hasOwn(SKILL_MEDIA_SLOTS, id) ? SKILL_MEDIA_SLOTS[id] : undefined;
}
