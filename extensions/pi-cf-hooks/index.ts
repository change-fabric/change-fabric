import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { callHook } from "../shared/cf-client.ts";
import { COMMAND_MODES, modeSlug } from "../shared/mode-slug.ts";

type Context = { cwd: string; sessionManager: { getSessionFile?: () => string | undefined } };

export default function cfHooks(pi: ExtensionAPI) {
  // Sessionless RPC runs get a process-local identity, never one shared by cwd.
  const ephemeralId = randomUUID();
  let reviewFollowUp = false;
  // Prompt-specific context (an away-mode plan refusal) is only computable from
  // the input hook, which sees the prompt; hold it for before_agent_start.
  let inputContext = "";
  let startupContext = "";
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
    const result = await callHook("pi", "SessionStart", { ...base(ctx), initial_mode: process.env.CF_MERGE_MODE });
    startupContext = result.hookSpecificOutput?.additionalContext ?? "";
  });
  pi.on("input", async (event, ctx) => {
    const result = await callHook("pi", "UserPromptSubmit", { ...base(ctx), prompt: event.text });
    inputContext = result.hookSpecificOutput?.additionalContext ?? "";
    return { action: "continue" };
  });
  pi.on("before_agent_start", async (event, ctx) => {
    const result = await callHook("pi", "UserPromptSubmit", base(ctx));
    const late = result.hookSpecificOutput?.additionalContext ?? "";
    const context = [startupContext, inputContext !== late ? inputContext : "", late].filter(Boolean).join("\n\n");
    startupContext = "";
    inputContext = "";
    return { systemPrompt: `${event.systemPrompt}\n\n${context}` };
  });
  pi.on("agent_end", async (_event, ctx) => {
    const result = await callHook("pi", "Stop", { ...base(ctx), stop_hook_active: reviewFollowUp });
    reviewFollowUp = result.decision === "block";
    if (reviewFollowUp && result.reason) pi.sendUserMessage(result.reason, { deliverAs: "followUp" });
    // A nonblocking notice (the review cap) arrives as context; show it without starting another turn.
    const notice = result.hookSpecificOutput?.additionalContext;
    if (!reviewFollowUp && notice) pi.sendMessage({ customType: "cf-hook", content: notice, display: true }, { deliverAs: "nextTurn" });
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
    const result = await callHook("pi", "PostToolUse", { ...base(ctx), tool_name: event.toolName, tool_input: event.input, tool_response: event.details ?? event.content, isError: event.isError });
    const text = result.hookSpecificOutput?.additionalContext;
    if (text) pi.sendMessage({ customType: "cf-hook", content: text, display: false }, { deliverAs: "steer" });
  });
}
