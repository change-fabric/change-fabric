// Pure helpers behind MediaSlot, kept free of React and the DOM so the site
// tests can run them directly under node --test.

export type MediaEntry = {
  kind: "video" | "audio";
  title: string;
  src: string;
  poster: string | null;
  vtt: string;
  words: string | null;
  duration_ms: number;
  width: number | null;
  height: number | null;
  bytes: number;
  alt: string;
  transcript: string;
};

export type Word = { text: string; start_ms: number; end_ms: number };

// 45000 -> "0:45", 61000 -> "1:01". Rounds to the nearest second.
export function formatDuration(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

// The word being spoken at `ms`, or -1 between words, before the first, or
// after the last. Words arrive sorted by start time, so this is a binary
// search for the last word that has started.
export function activeWordIndex(words: Word[], ms: number): number {
  let low = 0;
  let high = words.length - 1;
  let found = -1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (words[mid].start_ms <= ms) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  if (found === -1 || ms >= words[found].end_ms) return -1;
  return found;
}
