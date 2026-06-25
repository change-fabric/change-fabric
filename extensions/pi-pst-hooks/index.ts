import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type HookOutput = {
	decision?: string;
	reason?: string;
	systemMessage?: string;
	hookSpecificOutput?: {
		additionalContext?: string;
		permissionDecision?: string;
		permissionDecisionReason?: string;
	};
};

type HookContext = {
	cwd: string;
	sessionManager: { getSessionFile?: () => string | undefined };
};

type Selector = (message: string, options: string[]) => Promise<string | undefined>;

const HOOK_BIN = join(process.env.HOME ?? "", ".claude", "pst", "bin");
const RUBY = process.env.PST_RUBY ?? "ruby";
const MERGE_MODES = ["Local only", "Merge ready", "Admin bypass"] as const;
const PI_SESSION_PREFIX = "pi-";
const UNSET_MERGE_MODE_CONTEXT =
	"[pst pi] No merge mode is set for this Pi session. Pi does not have Claude Code AskUserQuestion parity in non-UI modes, so run /pst before pushing, opening PRs, or merging.";
const STOP_BEST_EFFORT_CONTEXT =
	"[pst pi] Pi has no blocking Stop hook. Treat this follow-up as a required review gate before declaring the work complete.";
const HOOK_TIMEOUT_MS = 5_000;

export default function pstHooks(pi: ExtensionAPI) {
	let pendingContext: string[] = [];
	let stopHookActive = false;

	pi.registerCommand("pst", {
		description: "Set the pst merge mode for this Pi session",
		handler: async (args, ctx) => {
			const mode = await resolveMode(args, ctx);
			if (!mode) return;
			writeMergeMode(sessionId(ctx), mode);
			ctx.ui.notify(`pst merge mode: ${mode}`, "info");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		await ensureMergeMode(ctx);
		if (readMergeMode(sessionId(ctx))) {
			await runAndQueue(pi, pendingContext, "session_start.rb", baseEvent(ctx));
		} else {
			pendingContext.push(UNSET_MERGE_MODE_CONTEXT);
		}
		await runAndQueue(pi, pendingContext, "skill_detect.rb", baseEvent(ctx));
	});

	pi.on("before_agent_start", async (event, ctx) => {
		await runAndQueue(pi, pendingContext, "merge_mode_restate.rb", baseEvent(ctx));
		if (pendingContext.length === 0) return undefined;

		const context = pendingContext.join("\n\n");
		pendingContext = [];
		return { systemPrompt: `${event.systemPrompt}\n\n${context}` };
	});

	pi.on("tool_call", async (event, ctx) => {
		const payload = toolEvent(ctx, event.toolName, event.input);
		for (const script of ["merge_mode_guard.rb", "glyph_guard.rb", "slop_remind.rb"]) {
			const output = await runHook(script, payload, ctx.cwd);
			const decision = output.hookSpecificOutput?.permissionDecision;
			if (decision === "deny") {
				return { block: true, reason: output.hookSpecificOutput?.permissionDecisionReason ?? "Blocked by pst hook" };
			}
			emitContext(pi, output.hookSpecificOutput?.additionalContext);
		}
		return undefined;
	});

	pi.on("tool_result", async (event, ctx) => {
		const payload = {
			...toolEvent(ctx, event.toolName, event.input),
			tool_response: event.details ?? event.content,
		};
		await runHook("merge_mode_record.rb", payload, ctx.cwd);
		const output = await runHook("skill_inject.rb", payload, ctx.cwd);
		emitContext(pi, output.hookSpecificOutput?.additionalContext);
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (stopHookActive) return;
		stopHookActive = true;
		try {
			const output = await runHook("skill_review.rb", { ...baseEvent(ctx), stop_hook_active: false }, ctx.cwd);
			if (output.systemMessage) emitContext(pi, output.systemMessage);
			if (output.decision === "block" && output.reason) {
				pi.sendUserMessage(`${STOP_BEST_EFFORT_CONTEXT}\n\n${output.reason}`, { deliverAs: "followUp" });
			}
		} finally {
			stopHookActive = false;
		}
	});
}

async function ensureMergeMode(ctx: HookContext & { hasUI?: boolean; ui?: { select?: Selector } }) {
	const id = sessionId(ctx);
	if (readMergeMode(id)) return;
	if (!ctx.hasUI || !ctx.ui?.select) return;

	const mode = await ctx.ui.select("Merge mode for this pst session", [...MERGE_MODES]);
	if (isMergeMode(mode)) writeMergeMode(id, mode);
}

async function resolveMode(args: string, ctx: HookContext & { hasUI?: boolean; ui: { select: Selector } }) {
	const normalized = args.trim().toLowerCase();
	const fromArgs = MERGE_MODES.find((mode) => mode.toLowerCase() === normalized);
	if (fromArgs) return fromArgs;
	if (!ctx.hasUI) return undefined;
	const mode = await ctx.ui.select("Merge mode", [...MERGE_MODES]);
	return isMergeMode(mode) ? mode : undefined;
}

function isMergeMode(value: string | undefined): value is (typeof MERGE_MODES)[number] {
	return MERGE_MODES.some((mode) => mode === value);
}

function baseEvent(ctx: HookContext) {
	return { session_id: sessionId(ctx), cwd: ctx.cwd };
}

function toolEvent(ctx: HookContext, piToolName: string, input: unknown) {
	const normalized = normalizeTool(piToolName, input);
	return { ...baseEvent(ctx), tool_name: normalized.name, tool_input: normalized.input };
}

function normalizeTool(toolName: string, input: unknown) {
	const data = isRecord(input) ? input : {};
	if (toolName === "bash") return { name: "Bash", input: data };
	if (toolName === "write") return { name: "Write", input: { ...data, file_path: data.path } };
	if (toolName === "edit") {
		const edits = Array.isArray(data.edits) ? data.edits.filter(isRecord) : [];
		const claudeEdits = edits.map((edit) => ({ old_string: edit.oldText, new_string: edit.newText }));
		return {
			name: claudeEdits.length > 1 ? "MultiEdit" : "Edit",
			input: {
				...data,
				file_path: data.path,
				old_string: claudeEdits[0]?.old_string,
				new_string: claudeEdits[0]?.new_string,
				edits: claudeEdits,
			},
		};
	}
	return { name: toolName, input: data };
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function runAndQueue(_pi: ExtensionAPI, pending: string[], script: string, event: Record<string, unknown>) {
	const output = await runHook(script, event, String(event.cwd ?? process.cwd()));
	const context = output.hookSpecificOutput?.additionalContext ?? output.systemMessage;
	if (context) pending.push(context);
}

function emitContext(pi: ExtensionAPI, context: string | undefined) {
	if (!context) return;
	pi.sendMessage({ customType: "pst-hook", content: context, display: true }, { deliverAs: "steer" });
}

function runHook(script: string, event: Record<string, unknown>, cwd: string): Promise<HookOutput> {
	return new Promise((resolve) => {
		const child = spawn(RUBY, [join(HOOK_BIN, script)], { cwd, stdio: ["pipe", "pipe", "ignore"] });
		let stdout = "";
		let settled = false;
		const finish = (output: HookOutput) => {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			resolve(output);
		};
		const timeout = setTimeout(() => {
			child.kill();
			finish({});
		}, HOOK_TIMEOUT_MS);
		child.stdout.on("data", (chunk: Buffer) => {
			stdout += chunk.toString();
		});
		child.on("error", () => finish({}));
		child.on("close", () => finish(parseHookOutput(stdout)));
		try {
			child.stdin.end(JSON.stringify(event));
		} catch {
			child.kill();
			finish({});
		}
	});
}

function parseHookOutput(stdout: string): HookOutput {
	const line = stdout.trim().split("\n").find((candidate) => candidate.trim().startsWith("{"));
	if (!line) return {};
	try {
		return toHookOutput(JSON.parse(line));
	} catch {
		return {};
	}
}

function toHookOutput(value: unknown): HookOutput {
	if (!isRecord(value)) return {};
	const output: HookOutput = {};
	if (typeof value.decision === "string") output.decision = value.decision;
	if (typeof value.reason === "string") output.reason = value.reason;
	if (typeof value.systemMessage === "string") output.systemMessage = value.systemMessage;
	const specific = value.hookSpecificOutput;
	if (isRecord(specific)) {
		const nested: NonNullable<HookOutput["hookSpecificOutput"]> = {};
		if (typeof specific.additionalContext === "string") nested.additionalContext = specific.additionalContext;
		if (typeof specific.permissionDecision === "string") nested.permissionDecision = specific.permissionDecision;
		if (typeof specific.permissionDecisionReason === "string") nested.permissionDecisionReason = specific.permissionDecisionReason;
		output.hookSpecificOutput = nested;
	}
	return output;
}

function sessionId(ctx: HookContext) {
	const raw = ctx.sessionManager.getSessionFile?.() ?? ctx.cwd;
	return `${PI_SESSION_PREFIX}${createHash("sha256").update(raw).digest("hex").slice(0, 32)}`;
}

function mergeModePath(id: string) {
	return join(process.env.HOME ?? "", ".claude", "pst", "sessions", id, "merge-mode");
}

function readMergeMode(id: string) {
	const path = mergeModePath(id);
	return existsSync(path) ? readFileSync(path, "utf8").trim() : undefined;
}

function writeMergeMode(id: string, mode: string) {
	const path = mergeModePath(id);
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `${mode}\n`);
}
