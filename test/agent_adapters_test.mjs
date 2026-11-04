import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import piHooks from "../extensions/pi-cf-hooks/index.ts";
import { CfHooks } from "../extensions/opencode-cf-hooks/index.ts";
import { callHook } from "../extensions/shared/cf-client.ts";

async function isolated(run) {
  const home = mkdtempSync(join(tmpdir(), "cf-adapter-"));
  const previous = { HOME: process.env.HOME, CF_STATE_HOME: process.env.CF_STATE_HOME, CF_RUNTIME_BIN: process.env.CF_RUNTIME_BIN };
  Object.assign(process.env, { HOME: home, CF_STATE_HOME: join(home, "state"), CF_RUNTIME_BIN: resolve("scripts") });
  try { await run(home); }
  finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    rmSync(home, { recursive: true, force: true });
  }
}

test("Pi handlers persist native commands and block through the real Ruby process", async () => isolated(async (home) => {
  const handlers = new Map();
  const commands = new Map();
  piHooks({ on: (event, handler) => handlers.set(event, handler), registerCommand: (name, command) => commands.set(name, command), sendMessage() {}, sendUserMessage() {} });
  const ctx = { cwd: home, sessionManager: { getSessionFile: () => "pi-session" }, ui: { notify() {} } };
  await handlers.get("session_start")({}, ctx);
  await commands.get("cf").handler("local-only", ctx);
  const result = await handlers.get("tool_call")({ toolName: "bash", input: { command: "git push" } }, ctx);
  assert.equal(result.block, true);
  const context = await handlers.get("before_agent_start")({ systemPrompt: "base" }, ctx);
  assert.match(context.systemPrompt, /local-only/);
}));

test("Pi sessionless instances do not share a cwd-derived identity", async () => isolated(async (home) => {
  const instances = [new Map(), new Map()];
  const commands = [];
  for (const handlers of instances) piHooks({ on: (event, handler) => handlers.set(event, handler), registerCommand: (_name, command) => commands.push(command), sendMessage() {}, sendUserMessage() {} });
  const ctx = { cwd: home, sessionManager: {}, ui: { notify() {} } };
  await commands[0].handler("local-only", ctx);
  const result = await instances[1].get("before_agent_start")({ systemPrompt: "base" }, ctx);
  assert.match(result.systemPrompt, /merge-ready/);
}));

test("OpenCode successful skill loads persist and children inherit without changing parents", async () => isolated(async (home) => {
  const plugin = await CfHooks({ directory: home, client: { session: { get: async ({ path }) => ({ data: { parentID: path.id === "child" ? "parent" : undefined } }) } } });
  const skill = { tool: "skill", sessionID: "parent", callID: "mode" };
  await plugin["tool.execute.before"](skill, { args: { name: "cf-local-only" } });
  await plugin["tool.execute.after"](skill, {});
  await assert.rejects(plugin["tool.execute.before"]({ tool: "bash", sessionID: "child", callID: "push" }, { args: { command: "git push" } }), /local-only/);
  const context = { system: [] };
  await plugin["experimental.chat.system.transform"]({ sessionID: "parent" }, context);
  assert.match(context.system.join("\n"), /local-only/);
}));

test("client rejects missing runtime and enforces its timeout", async () => isolated(async (home) => {
  process.env.CF_RUNTIME_BIN = join(home, "missing");
  await assert.rejects(callHook("pi", "SessionStart", { cwd: home, session_id: "x" }));
  const bin = join(home, "slow");
  mkdirSync(bin);
  writeFileSync(join(bin, "cf_host_hook.rb"), "sleep 5\n");
  process.env.CF_RUNTIME_BIN = bin;
  await assert.rejects(callHook("pi", "SessionStart", { cwd: home, session_id: "x" }, 40), /timed out/);
}));


test("Pi environment defaults do not overwrite a resumed session", async () => isolated(async (home) => {
  const previous = process.env.CF_MERGE_MODE;
  process.env.CF_MERGE_MODE = "local-only";
  try {
    const handlers = new Map();
    let command;
    piHooks({ on: (event, handler) => handlers.set(event, handler), registerCommand: (_name, value) => { command = value; }, sendMessage() {}, sendUserMessage() {} });
    const ctx = { cwd: home, sessionManager: { getSessionFile: () => "resumed" }, ui: { notify() {} } };
    await handlers.get("session_start")({}, ctx);
    await command.handler("yolo", ctx);
    await handlers.get("session_start")({}, ctx);
    const result = await handlers.get("before_agent_start")({ systemPrompt: "base" }, ctx);
    assert.match(result.systemPrompt, /Merge mode: yolo/);
  } finally { if (previous === undefined) delete process.env.CF_MERGE_MODE; else process.env.CF_MERGE_MODE = previous; }
}));

test("client rejects a failed process that did not return a native deny", async () => isolated(async (home) => {
  const bin = join(home, "invalid");
  mkdirSync(bin);
  writeFileSync(join(bin, "cf_host_hook.rb"), 'puts "{}"; exit 2\n');
  process.env.CF_RUNTIME_BIN = bin;
  await assert.rejects(callHook("pi", "PreToolUse", { cwd: home, session_id: "x" }), /no policy|without a native deny/);
}));

test("Pi and OpenCode deliver startup rubric detection into model context", async () => isolated(async (home) => {
  const project = join(home, "project");
  const skills = join(home, ".local/share/change-fabric/source-skills/ruby");
  mkdirSync(project);
  mkdirSync(skills, { recursive: true });
  writeFileSync(join(project, "Gemfile"), "source 'https://rubygems.org'\n");
  writeFileSync(join(skills, "SKILL.md"), "---\nname: cf:ruby\ndescription: Ruby\nauto:\n  detect: [Gemfile]\n---\nRuby rules.\n");
  const handlers = new Map();
  piHooks({ on: (event, handler) => handlers.set(event, handler), registerCommand() {}, sendMessage() {}, sendUserMessage() {} });
  const ctx = { cwd: project, sessionManager: { getSessionFile: () => "pi-startup" }, ui: { notify() {} } };
  await handlers.get("session_start")({}, ctx);
  const piContext = await handlers.get("before_agent_start")({ systemPrompt: "base" }, ctx);
  assert.match(piContext.systemPrompt, /Auto-skills active.*cf:ruby/);
  const plugin = await CfHooks({ directory: project });
  const output = { system: [] };
  await plugin["experimental.chat.system.transform"]({ sessionID: "opencode-startup" }, output);
  assert.match(output.system.join("\n"), /Auto-skills active.*cf:ruby/);
}));
