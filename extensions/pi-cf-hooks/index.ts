import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { callHook } from "../shared/cf-client.ts";
import { COMMAND_MODES, MERGE_MODES, modeSlug } from "../shared/mode-slug.ts";

type Context = { cwd: string; sessionManager: { getSessionFile?: () => string | undefined } };

export default function cfHooks(pi: ExtensionAPI) {
  // Sessionless RPC runs get a process-local identity, never one shared by cwd.
  const ephemeralId = randomUUID();
  let reviewFollowUp = false;
  const base = (ctx: Context) => ({ cwd: ctx.cwd, session_id: ctx.sessionManager.getSessionFile?.() ?? ephemeralId });
  pi.registerCommand("cf", {
    description: "Set merge mode: local-only, merge-ready, admin-bypass, or yolo",
    handler: async (args, ctx) => {
      const mode = modeSlug(args, COMMAND_MODES);
      if (!mode) {
        ctx.ui.notify("Use /cf local-only|merge-ready|admin-bypass|yolo|away|active", "info");
        return;
      }
      await callHook("pi", "UserPromptSubmit", { ...base(ctx), prompt: `/skill:cf-${mode}` });
      ctx.ui.notify(`CF mode: ${mode}`, "info");
    },
  });
  pi.on("session_start", async (_event, ctx) => {
    await callHook("pi", "SessionStart", base(ctx));
    const envMode = modeSlug(process.env.CF_MERGE_MODE, MERGE_MODES);
    if (envMode) {
      // A default only: a resumed session keeps the mode it last chose with /cf.
      await callHook("pi", "UserPromptSubmit", { ...base(ctx), prompt: `/skill:cf-${envMode}`, cf_default: true });
    }
  });
  pi.on("input", async (event, ctx) => {
    await callHook("pi", "UserPromptSubmit", { ...base(ctx), prompt: event.text });
    return { action: "continue" };
  });
  pi.on("before_agent_start", async (event, ctx) => {
    const result = await callHook("pi", "UserPromptSubmit", base(ctx));
    return { systemPrompt: `${event.systemPrompt}\n\n${result.hookSpecificOutput?.additionalContext ?? ""}` };
  });
  pi.on("agent_end", async (_event, ctx) => {
    const result = await callHook("pi", "Stop", { ...base(ctx), stop_hook_active: reviewFollowUp });
    reviewFollowUp = result.decision === "block";
    if (reviewFollowUp && result.reason) pi.sendUserMessage(result.reason, { deliverAs: "followUp" });
  });
  pi.on("tool_call", async (event, ctx) => {
    const result = await callHook("pi", "PreToolUse", { ...base(ctx), tool_name: event.toolName, tool_input: event.input });
    if (result.hookSpecificOutput?.additionalContext) pi.sendMessage({ customType: "cf-hook", content: result.hookSpecificOutput.additionalContext, display: false }, { deliverAs: "steer" });
    if (result.hookSpecificOutput?.permissionDecision === "deny") {
      return { block: true, reason: result.hookSpecificOutput.permissionDecisionReason ?? "CF denied this call" };
    }
    return undefined;
  });
  pi.on("tool_result", async (event, ctx) => {
    const result = await callHook("pi", "PostToolUse", { ...base(ctx), tool_name: event.toolName, tool_input: event.input, isError: event.isError });
    const text = result.hookSpecificOutput?.additionalContext;
    if (text) pi.sendMessage({ customType: "cf-hook", content: text, display: false }, { deliverAs: "steer" });
  });
}
