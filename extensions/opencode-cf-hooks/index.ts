import { callHook, isRecord } from "../shared/cf-client.ts";

type ToolCall = { tool: string; sessionID?: string; callID?: string };
type SessionClient = { session?: { get?: (req: { path: { id: string } }) => Promise<{ data?: { parentID?: string } }> } };

export const CfHooks = async ({ directory, client }: { directory: string; client?: SessionClient }) => {
  const initialized = new Map<string, Promise<void>>();
  const pending = new Map<string, Record<string, unknown>>();
  const ensureSession = (id: string): Promise<void> => {
    let ready = initialized.get(id);
    if (!ready) {
      ready = (async () => {
        const parent = await client?.session?.get?.({ path: { id } });
        await callHook("opencode", "SubagentStart", { session_id: id, parent_session_id: parent?.data?.parentID, cwd: directory });
      })();
      initialized.set(id, ready);
      ready.catch(() => initialized.delete(id));
    }
    return ready;
  };
  return {
    "tool.execute.before": async (input: ToolCall, output: { args?: unknown }) => {
      if (!input.sessionID) throw new Error("CF requires a stable OpenCode session ID");
      await ensureSession(input.sessionID);
      const args = isRecord(output.args) ? output.args : {};
      const payload = { session_id: input.sessionID, cwd: directory, tool_name: input.tool, tool_input: args };
      const result = await callHook("opencode", "PreToolUse", payload);
      if (result.hookSpecificOutput?.permissionDecision === "deny") throw new Error(result.hookSpecificOutput.permissionDecisionReason);
      // OpenCode cannot add context to a running call, so a rubric reminder blocks
      // once; the hook marks it surfaced, so the retry goes through.
      const reminder = result.hookSpecificOutput?.rubricContext;
      if (reminder) throw new Error(`${reminder}\n\nReview the command against this, then run it again.`);
      // A mode is recorded only after the skill actually loads successfully.
      if (pending.size >= 256) pending.clear();
      pending.set(input.callID ?? input.sessionID, payload);
    },
    "tool.execute.after": async (input: ToolCall, output: { output?: string; metadata?: unknown }) => {
      if (!input.sessionID) return;
      const key = input.callID ?? input.sessionID;
      const payload = pending.get(key);
      pending.delete(key);
      if (payload) {
        const result = await callHook("opencode", "PostToolUse", { ...payload, tool_response: output.metadata ?? {} });
        if (result.hookSpecificOutput?.additionalContext) output.output = `${output.output ?? ""}\n\n${result.hookSpecificOutput.additionalContext}`;
      }
    },
    "experimental.chat.system.transform": async (input: { sessionID?: string }, output: { system: string[] }) => {
      if (!input.sessionID) return;
      await ensureSession(input.sessionID);
      const result = await callHook("opencode", "UserPromptSubmit", { session_id: input.sessionID, cwd: directory });
      if (result.hookSpecificOutput?.additionalContext) output.system.push(result.hookSpecificOutput.additionalContext);
    },
    "experimental.session.compacting": async (input: { sessionID: string }, output: { context: string[] }) => {
      const result = await callHook("opencode", "PostCompact", { session_id: input.sessionID, cwd: directory });
      if (result.hookSpecificOutput?.additionalContext) output.context.push(result.hookSpecificOutput.additionalContext);
    },
  };
};
