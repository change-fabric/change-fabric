import { useEffect, useRef, useState } from "react";

// Copies a permalink to the clipboard, with a transient confirmation. Same
// interaction as CodeBlock's copy control: progressive, so where the clipboard
// API is unavailable nothing breaks and the address bar still works.
export function CopyLink({ url, label }: { url: string; label: string }) {
  const [copied, setCopied] = useState(false);
  const resetTimer = useRef<number | undefined>(undefined);

  // Clear a pending reset if the button unmounts, so the timeout never fires
  // on an unmounted component.
  useEffect(() => () => window.clearTimeout(resetTimer.current), []);

  async function copy() {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      window.clearTimeout(resetTimer.current);
      resetTimer.current = window.setTimeout(() => setCopied(false), 1500);
    } catch {
      // No clipboard access; the link is still reachable from the address bar.
    }
  }

  return (
    <button type="button" className="code-copy changelog-copy" onClick={copy} aria-label={label}>
      {copied ? "Copied" : "Copy link"}
    </button>
  );
}
