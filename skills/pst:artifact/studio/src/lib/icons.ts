/**
 * A small, self-contained stroke-icon set (24x24, currentColor) so artifacts
 * stay offline-safe with no icon CDN. Each value is the inner markup of an
 * <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"
 * stroke-linecap="round" stroke-linejoin="round">. Add more as needed.
 */
export const ICONS: Record<string, string> = {
  "arrow-right": '<path d="M5 12h14M13 6l6 6-6 6"/>',
  "arrow-up-right": '<path d="M7 17 17 7M8 7h9v9"/>',
  check: '<path d="m20 6-11 11-5-5"/>',
  "check-circle":
    '<circle cx="12" cy="12" r="9"/><path d="m8.5 12 2.5 2.5 4.5-5"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  warning:
    '<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
  lightbulb:
    '<path d="M9 18h6M10 22h4M12 2a7 7 0 0 0-4 12.7c.6.5 1 1.3 1 2.1V18h6v-1.2c0-.8.4-1.6 1-2.1A7 7 0 0 0 12 2Z"/>',
  rocket:
    '<path d="M5 16c-1.5 1.3-2 5-2 5s3.7-.5 5-2c.7-.8.7-2 0-2.8a2 2 0 0 0-3 0ZM12 15l-3-3a16 16 0 0 1 7-9c2 0 4 0 5 1s1 3 1 5a16 16 0 0 1-9 7Z"/><circle cx="14" cy="10" r="1.5"/>',
  layers: '<path d="m12 3 9 5-9 5-9-5 9-5ZM3 13l9 5 9-5M3 17l9 5 9-5"/>',
  database:
    '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
  "git-branch":
    '<circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="8" r="2"/><path d="M6 8v8M18 10a6 6 0 0 1-6 6H8"/>',
  shield: '<path d="M12 3 5 6v6c0 4.5 3 7.5 7 9 4-1.5 7-4.5 7-9V6l-7-3Z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  target:
    '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.5"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  users:
    '<circle cx="9" cy="8" r="3"/><path d="M3 20a6 6 0 0 1 12 0M16 5.5a3 3 0 0 1 0 5M21 20a6 6 0 0 0-4-5.6"/>',
  sparkle:
    '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3ZM19 14l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7.7-2Z"/>',
  link: '<path d="M9 15l6-6M10.5 6.5 13 4a4 4 0 0 1 6 6l-2.5 2.5M13.5 17.5 11 20a4 4 0 0 1-6-6l2.5-2.5"/>',
  chart: '<path d="M4 20V4M4 20h16M8 16v-4M12 16V8M16 16v-6"/>',
  gauge:
    '<path d="M12 14 16 9M21 14a9 9 0 1 0-18 0"/><circle cx="12" cy="14" r="1.5"/>',
  lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  bolt: '<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8Z"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>',
  flow: '<rect x="3" y="4" width="6" height="5" rx="1"/><rect x="15" y="4" width="6" height="5" rx="1"/><rect x="9" y="15" width="6" height="5" rx="1"/><path d="M6 9v3a2 2 0 0 0 2 2h2M18 9v3a2 2 0 0 1-2 2h-2"/>',
  map: '<path d="m9 4 6 2 6-2v14l-6 2-6-2-6 2V6l6-2ZM9 4v14M15 6v14"/>',
  compass: '<circle cx="12" cy="12" r="9"/><path d="m15 9-2 4-4 2 2-4 4-2Z"/>',
  book: '<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2V5ZM4 19a2 2 0 0 1 2-2h13"/>',
  puzzle:
    '<path d="M14 4a2 2 0 1 0-4 0H6v4a2 2 0 1 1 0 4v4h4a2 2 0 1 1 4 0h4v-4a2 2 0 1 0 0-4V4h-4Z"/>',
};

export type IconName = keyof typeof ICONS;
