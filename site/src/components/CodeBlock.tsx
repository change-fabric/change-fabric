import { useEffect, useRef, useState } from "react";

// A fenced code block with a copy button. The copy is progressive: where the
// clipboard API is unavailable the block is still fully selectable by hand.
export function CodeBlock({ code, label }: { code: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  const resetTimer = useRef<number>();

  // Clear a pending reset if the block unmounts, so the timeout never fires on
  // an unmounted component.
  useEffect(() => () => window.clearTimeout(resetTimer.current), []);

  async function copy() {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
      window.clearTimeout(resetTimer.current);
      resetTimer.current = window.setTimeout(() => setCopied(false), 1500);
    } catch {
      // No clipboard access; the user can still select and copy manually.
    }
  }

  return (
    <div className="code-block">
      <div className="code-block-bar">
        <span className="code-block-label">{label}</span>
        <button type="button" className="code-copy" onClick={copy}>
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <pre>
        <code>{code}</code>
      </pre>
    </div>
  );
}
