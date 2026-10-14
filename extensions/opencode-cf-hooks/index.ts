import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

// Partial cf hooks for OpenCode, mirroring extensions/pi-cf-hooks: bash calls
// are mapped to a PreToolUse event for merge_mode_guard.rb and slop_remind.rb,
// and a deny from either hook blocks the call by throwing. OpenCode has no way
// to add context to a running call, so a reminder (additionalContext) also
// blocks it once: the hook records the reminder as surfaced, so the agent reads
// it in the error and the retry goes through.

type HookOutput = {
	hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string; additionalContext?: string };
};

const HOOK_BIN = join(process.env.HOME ?? "", ".claude", "cf", "bin");
const RUBY = process.env.CF_RUBY ?? "ruby";
const HOOK_TIMEOUT_MS = 5_000;

type ToolInput = { tool: string; sessionID?: string; callID?: string };
type SessionClient = { session?: { get?: (req: { path: { id: string } }) => Promise<{ data?: { parentID?: string } }> } };

export const CfHooks = async ({ directory, client }: { directory: string; client?: SessionClient }) => {
	// A task subagent runs in a child session with its own id, so the merge mode
	// is keyed by the root of the parent chain: a child inherits the mode its
	// primary session selected. A failed lookup keys by the session itself.
	const roots = new Map<string, Promise<string>>();
	const rootSession = (id: string): Promise<string> => {
		let root = roots.get(id);
		if (!root) {
			root = (async () => {
				const seen = new Set([id]);
				let current = id;
				for (;;) {
					const parent = await client?.session?.get?.({ path: { id: current } }).then((res) => res?.data?.parentID).catch(() => undefined);
					if (!parent || seen.has(parent)) return current;
					seen.add(parent);
					current = parent;
				}
			})();
			roots.set(id, root);
		}
		return root;
	};
	const sessionKey = async (input: ToolInput) =>
		`opencode-${createHash("sha256").update(input.sessionID ? await rootSession(input.sessionID) : directory).digest("hex").slice(0, 32)}`;
	// Loading a mirrored mode skill (cf-local-only and friends) persists that
	// mode, as mode_command.rb does for Claude Code. The skill tool checks its
	// permissions while executing, so the mode is noted here and written only
	// from tool.execute.after, which runs once the load has succeeded.
	const pendingModes = new Map<string, string>();
	return {
		"tool.execute.after": async (input: ToolInput) => {
			const key = input.callID ?? (await sessionKey(input));
			const mode = pendingModes.get(key);
			pendingModes.delete(key);
			if (input.tool === "skill" && mode) writeMergeMode(await sessionKey(input), mode);
		},
		"tool.execute.before": async (input: ToolInput, output: { args?: unknown }) => {
			const id = await sessionKey(input);
			if (input.tool === "skill") {
				const mode = /^cf[-:](local-only|merge-ready|admin-bypass|yolo)$/.exec(String((output.args as { name?: unknown })?.name ?? ""))?.[1];
				if (mode) pendingModes.set(input.callID ?? id, mode);
				return;
			}
			if (input.tool !== "bash") return;
			// The command runs in args.workdir when given, so the guards must too.
			const workdir = (output.args as { workdir?: unknown } | undefined)?.workdir;
			const cwd = typeof workdir === "string" && workdir ? resolve(directory, workdir) : directory;
			const payload = { session_id: id, cwd, tool_name: "Bash", tool_input: output.args ?? {} };
			for (const script of ["merge_mode_guard.rb", "slop_remind.rb"]) {
				const hook = (await runHook(script, payload, cwd)).hookSpecificOutput;
				if (hook?.permissionDecision === "deny") throw new Error(hook.permissionDecisionReason ?? "Blocked by cf hook");
				if (hook?.additionalContext) throw new Error(`${hook.additionalContext}\n\nReview the command against this, then run it again.`);
			}
		},
	};
};

function runHook(script: string, event: Record<string, unknown>, cwd: string): Promise<HookOutput> {
	return new Promise((done) => {
		const child = spawn(RUBY, [join(HOOK_BIN, script)], { cwd, stdio: ["pipe", "pipe", "ignore"] });
		let stdout = "";
		let settled = false;
		const finish = (result: HookOutput) => {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			done(result);
		};
		// Settle on the timer itself, so a hook that ignores the kill cannot hang the call.
		const timeout = setTimeout(() => {
			child.kill();
			finish({});
		}, HOOK_TIMEOUT_MS);
		child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
		child.on("error", () => finish(parse(stdout)));
		child.on("close", () => finish(parse(stdout)));
		child.stdin.on("error", () => {});
		child.stdin.end(JSON.stringify(event));
	});
}

function parse(stdout: string): HookOutput {
	const line = stdout.trim().split("\n").find((candidate) => candidate.trim().startsWith("{"));
	try {
		return line ? (JSON.parse(line) as HookOutput) : {};
	} catch {
		return {};
	}
}

function writeMergeMode(id: string, mode: string) {
	const path = join(process.env.HOME ?? "", ".claude", "cf", "sessions", id, "merge-mode");
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `${mode}\n`);
}
