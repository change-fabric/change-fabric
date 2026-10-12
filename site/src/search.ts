// Forgiving search for the /reference index, with no dependency. A query
// matches when every word in it finds a word in the entry, and a word finds
// another when, after both are lowercased and stemmed, one is:
//   exact          "status" and "status"
//   a prefix       "sta" and "status", the as-you-type case
//   stem-equal     "reviewing" and "reviews" (both stem to "review")
//   one typo away  "staus" and "status"; two for words of 8+ letters
// Punctuation splits words, so "cf sta" finds "cf:status" and "away guard"
// finds "away_guard.rb"; a run-together query ("cfstatus") is also tried
// against the name with its punctuation squeezed out.

interface Searchable {
  name: string;
  description: string;
}

interface Indexed {
  nameWords: string[];
  textWords: string[];
  squeezed: string;
}

// Field weights: a hit in the name outranks the same hit in the prose.
const NAME = 3;
const TEXT = 1;
// Kind weights: exact beats prefix beats stem beats a typo.
const EXACT = 4;
const PREFIX = 3;
const STEM = 2;
const TYPO = 1;
// A query that also reads as the start of the squeezed name ("cf sta" for
// cf:status) earns this multiple on top of its word scores.
const WHOLE_BONUS = 2;

function words(value: string): string[] {
  return value.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}

// A light English suffix stripper, not Porter: enough that plurals, -ing,
// -ed and -er forms meet their base word, without the surprises of a full
// stemmer on identifiers. Words under 4 letters are left alone.
export function stem(word: string): string {
  if (word.length < 4 || /\d/.test(word)) return word;
  const rules: [RegExp, string][] = [
    [/ies$/, "y"],
    [/(ss|sh|ch|x|z)es$/, "$1"],
    [/([^s])s$/, "$1"],
    [/(.{3,})ing$/, "$1"],
    [/(.{3,})ed$/, "$1"],
    [/(.{3,})er$/, "$1"],
  ];
  for (const [pattern, replacement] of rules) {
    if (pattern.test(word)) {
      const stemmed = word.replace(pattern, replacement);
      // "running" -> "runn" -> "run"; "staged" stays "stag", which only has
      // to agree with itself, since both sides go through this function.
      return /([^aeiouls])\1$/.test(stemmed) ? stemmed.slice(0, -1) : stemmed;
    }
  }
  return word;
}

// Damerau-Levenshtein (optimal string alignment), stopping once over `max`.
function within(a: string, b: string, max: number): boolean {
  if (Math.abs(a.length - b.length) > max) return false;
  let prev2: number[] = [];
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const row = [i];
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let value = Math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        value = Math.min(value, prev2[j - 2] + 1);
      }
      row.push(value);
      best = Math.min(best, value);
    }
    if (best > max) return false;
    prev2 = prev;
    prev = row;
  }
  return prev[b.length] <= max;
}

function typoBudget(word: string): number {
  if (word.length >= 8) return 2;
  if (word.length >= 4) return 1;
  return 0;
}

// The best kind of match `term` makes against one word, or 0.
function matchWord(term: string, word: string): number {
  if (word === term) return EXACT;
  if (word.startsWith(term)) return PREFIX;
  const a = stem(term);
  const b = stem(word);
  if (a === b || b.startsWith(a)) return STEM;
  const budget = typoBudget(term);
  if (budget === 0) return 0;
  // A typo in a word still being typed: compare against the start of the
  // word as well as the whole of it.
  if (within(term, word, budget) || within(term, word.slice(0, term.length), budget)) {
    return TYPO;
  }
  return 0;
}

function bestIn(term: string, list: string[]): number {
  let best = 0;
  for (const word of list) {
    best = Math.max(best, matchWord(term, word));
    if (best === EXACT) break;
  }
  return best;
}

function matchSqueezed(whole: string, squeezed: string): number {
  if (squeezed === whole) return EXACT;
  if (squeezed.startsWith(whole)) return PREFIX;
  return squeezed.includes(whole) ? STEM : 0;
}

function index(entry: Searchable): Indexed {
  return {
    nameWords: words(entry.name),
    textWords: words(entry.description),
    squeezed: entry.name.toLowerCase().replace(/[^a-z0-9]+/g, ""),
  };
}

// Builds a scorer over `entries`; the returned function gives each entry's
// score for a query, 0 meaning no match. An empty query matches everything.
export function createSearch<T extends Searchable>(entries: T[]) {
  const indexed = new Map(entries.map((entry) => [entry, index(entry)]));
  return (query: string, entry: T): number => {
    const terms = words(query);
    if (terms.length === 0) return 1;
    const { nameWords, textWords, squeezed } = indexed.get(entry) ?? index(entry);
    // "cf sta" and "cfsta" both read as the start of "cfstatus"; a
    // run-together query has no word boundary, so this is its only route.
    const whole = terms.join("");
    const squeezedHit = whole.length < 3 ? 0 : matchSqueezed(whole, squeezed);
    let total = 0;
    for (const term of terms) {
      const score = Math.max(bestIn(term, nameWords) * NAME, bestIn(term, textWords) * TEXT);
      if (score === 0) return squeezedHit * NAME;
      total += score;
    }
    return total + squeezedHit * NAME * WHOLE_BONUS;
  };
}
