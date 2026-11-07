import { spawn } from "node:child_process";
import { join } from "node:path";

export type CfOutput = {
  decision?: string;
  reason?: string;
  additionalContext?: string;
  systemMessage?: string;
  hookSpecificOutput?: { additionalContext?: string; permissionDecision?: string; permissionDecisionReason?: string; rubricContext?: string };
};

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Reject on failure; a missing runtime must not be reported as a policy allow.
export function callHook(host: string, event: string, payload: Record<string, unknown>, timeoutMs = 5000): Promise<CfOutput> {
  const bin = process.env.CF_RUNTIME_BIN ?? join(process.env.HOME ?? "", ".local", "share", "change-fabric", "bin");
  return new Promise((resolve, reject) => {
    const child = spawn(process.env.CF_RUBY ?? "ruby", [join(bin, "cf_host_hook.rb"), host, event],
      { cwd: typeof payload.cwd === "string" ? payload.cwd : process.cwd(), stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const fail = (error: Error) => { if (!settled) { settled = true; clearTimeout(timer); child.kill("SIGKILL"); reject(error); } };
    const timer = setTimeout(() => fail(new Error("CF runtime timed out; policy was not evaluated")), timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (stdout.length > 1024 * 1024) fail(new Error("CF output exceeded 1 MiB"));
    });
    child.stderr.on("data", (chunk: Buffer) => { stderr = (stderr + chunk.toString()).slice(-4096); });
    child.stdin.on("error", fail);
    child.on("error", fail);
    child.on("close", (code) => {
      if (settled) return;
      try {
        const output: unknown = JSON.parse(stdout);
        if (!isRecord(output)) throw new Error("Invalid CF output");
        if (code !== 0 && code !== 2) throw new Error(stderr || "CF runtime failed");
        const specific = isRecord(output.hookSpecificOutput) ? output.hookSpecificOutput : undefined;
        // `{}` with exit 0 is a plain allow (and how a fail-silent hook error ends).
        if (code === 2 && specific?.permissionDecision !== "deny") throw new Error("CF failed without a native deny response");
        settled = true;
        clearTimeout(timer);
        resolve(output);
      } catch (error) { fail(error instanceof Error ? error : new Error(String(error))); }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}
