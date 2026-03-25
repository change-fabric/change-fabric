#!/usr/bin/env node
'use strict';

// CDP Bridge - Chrome DevTools Protocol helper for QA testing.
// Zero npm dependencies. Requires Node 22+ (native WebSocket).
//
// Commands:
//   launch    - Start Chrome with remote debugging, return connection info
//   stream    - Background process that logs CDP events to a JSONL file
//   capture   - One-shot queries: dom, screenshot, url, metrics
//   run       - Execute browser actions: navigate, click, type, focus, evaluate
//   teardown  - Kill Chrome + stream processes, clean up temp files

const { parseArgs } = require('node:util');
const { execSync, spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const http = require('node:http');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const { values: args, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    port:    { type: 'string', short: 'p' },
    url:     { type: 'string', short: 'u' },
    output:  { type: 'string', short: 'o' },
    type:    { type: 'string', short: 't' },
    expr:    { type: 'string', short: 'e' },
    text:    { type: 'string' },
    selector:{ type: 'string', short: 's' },
    x:       { type: 'string' },
    y:       { type: 'string' },
    save:    { type: 'string' },
    pid:     { type: 'string' },
    profile: { type: 'string' },
    stream:  { type: 'string' },
    timeout: { type: 'string', default: '30000' },
  },
});

const command = positionals[0];

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function ok(data) {
  console.log(JSON.stringify({ ok: true, ...data }));
  process.exit(0);
}

function fail(code, detail) {
  console.log(JSON.stringify({ ok: false, code, detail }));
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Chrome location
// ---------------------------------------------------------------------------

function locateBrowser() {
  // Env override first
  if (process.env.CHROME_PATH && fs.existsSync(process.env.CHROME_PATH)) {
    return process.env.CHROME_PATH;
  }

  const platform = os.platform();

  if (platform === 'darwin') {
    const candidates = [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ];
    for (const c of candidates) {
      if (fs.existsSync(c)) return c;
    }
  }

  if (platform === 'win32') {
    const roots = [process.env.PROGRAMFILES, process.env['PROGRAMFILES(X86)'], process.env.LOCALAPPDATA].filter(Boolean);
    const suffixes = ['Google\\Chrome\\Application\\chrome.exe', 'Google\\Chrome Dev\\Application\\chrome.exe'];
    for (const root of roots) {
      for (const suffix of suffixes) {
        const full = path.join(root, suffix);
        if (fs.existsSync(full)) return full;
      }
    }
  }

  // Linux / fallback - try PATH
  const names = ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser'];
  for (const name of names) {
    try {
      const found = execSync(`which ${name} 2>/dev/null`, { encoding: 'utf8' }).trim();
      if (found) return found;
    } catch { /* not found, try next */ }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Port helpers
// ---------------------------------------------------------------------------

function getAvailablePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(new Error(`Invalid JSON from ${url}: ${data.slice(0, 200)}`)); }
      });
    }).on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Async pause
// ---------------------------------------------------------------------------

function pause(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// ChromeLink - CDP WebSocket connection
// ---------------------------------------------------------------------------

class ChromeLink {
  constructor(ws) {
    this._ws = ws;
    this._id = 0;
    this._pending = new Map();
    this._listeners = new Map();

    ws.addEventListener('message', (event) => {
      let msg;
      try { msg = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString()); }
      catch { return; }

      if (msg.id !== undefined && this._pending.has(msg.id)) {
        const { resolve, reject } = this._pending.get(msg.id);
        this._pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message));
        else resolve(msg.result);
      }

      if (msg.method) {
        const fns = this._listeners.get(msg.method) || [];
        for (const fn of fns) fn(msg.params);
      }
    });
  }

  static async attach(port) {
    if (typeof globalThis.WebSocket === 'undefined') {
      fail('node-version', 'Node 22+ required for native WebSocket. Current: ' + process.version);
    }

    // Get WebSocket debugger URL
    let targets;
    for (let attempt = 0; attempt < 15; attempt++) {
      try {
        targets = await fetchJson(`http://127.0.0.1:${port}/json`);
        break;
      } catch {
        await pause(500);
      }
    }

    if (!targets) fail('connect', `Could not reach Chrome DevTools on port ${port}`);

    const page = targets.find((t) => t.type === 'page');
    if (!page) fail('connect', 'No page target found in Chrome');

    const wsUrl = page.webSocketDebuggerUrl;

    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve);
      ws.addEventListener('error', (e) => reject(new Error('WebSocket connect failed')));
      setTimeout(() => reject(new Error('WebSocket connect timeout')), 10000);
    });

    return new ChromeLink(ws);
  }

  send(method, params = {}) {
    const id = ++this._id;
    const timeoutMs = parseInt(args.timeout) || 30000;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`CDP timeout: ${method} after ${timeoutMs}ms`));
      }, timeoutMs);

      this._pending.set(id, {
        resolve: (result) => { clearTimeout(timer); resolve(result); },
        reject: (err) => { clearTimeout(timer); reject(err); },
      });

      this._ws.send(JSON.stringify({ id, method, params }));
    });
  }

  on(method, fn) {
    if (!this._listeners.has(method)) this._listeners.set(method, []);
    this._listeners.get(method).push(fn);
  }

  close() {
    this._ws.close();
  }
}

// ---------------------------------------------------------------------------
// Command: launch
// ---------------------------------------------------------------------------

async function handleLaunch() {
  const browser = locateBrowser();
  if (!browser) fail('no-chrome', 'Chrome or Chromium not found. Set CHROME_PATH env to override.');

  const debugPort = await getAvailablePort();
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pst-qa-'));
  const startUrl = args.url || 'about:blank';

  const chromeArgs = [
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${tempDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-default-apps',
    '--disable-extensions',
    '--disable-sync',
    '--disable-translate',
    '--disable-gpu',
    '--metrics-recording-only',
    '--mute-audio',
    `--window-size=1280,900`,
    startUrl,
  ];

  const chrome = spawn(browser, chromeArgs, {
    detached: true,
    stdio: 'ignore',
  });
  chrome.unref();

  // Wait for DevTools endpoint to be reachable
  let wsUrl = null;
  for (let i = 0; i < 30; i++) {
    try {
      const targets = await fetchJson(`http://127.0.0.1:${debugPort}/json`);
      const page = targets.find((t) => t.type === 'page');
      if (page) { wsUrl = page.webSocketDebuggerUrl; break; }
    } catch { /* retry */ }
    await pause(300);
  }

  if (!wsUrl) {
    try { process.kill(chrome.pid); } catch {}
    fail('launch', 'Chrome started but DevTools endpoint never became reachable');
  }

  ok({
    chromePid: chrome.pid,
    port: debugPort,
    tempDir,
    websocketUrl: wsUrl,
  });
}

// ---------------------------------------------------------------------------
// Command: stream
// ---------------------------------------------------------------------------

async function handleStream() {
  const port = parseInt(args.port);
  if (!port) fail('args', '--port is required for stream command');

  const outputPath = args.output || path.join(os.tmpdir(), `pst-qa-stream-${Date.now()}.jsonl`);
  const fd = fs.openSync(outputPath, 'a');

  let link;
  try {
    link = await ChromeLink.attach(port);
  } catch (e) {
    fs.closeSync(fd);
    throw e;
  }

  function write(src, evt, payload) {
    const line = JSON.stringify({ t: Date.now(), src, evt, payload });
    fs.writeSync(fd, line + '\n');
  }

  function cleanup() {
    try { fs.closeSync(fd); } catch { /* already closed */ }
    try { link.close(); } catch { /* already closed */ }
  }

  // Enable domains
  await link.send('Runtime.enable');
  await link.send('Network.enable');
  await link.send('Page.enable');

  // Console
  link.on('Runtime.consoleAPICalled', (p) => {
    write('console', p.type, {
      text: p.args.map((a) => a.value ?? a.description ?? '').join(' '),
      url: p.stackTrace?.callFrames?.[0]?.url,
    });
  });

  link.on('Runtime.exceptionThrown', (p) => {
    write('console', 'exception', {
      text: p.exceptionDetails?.text || '',
      description: p.exceptionDetails?.exception?.description || '',
    });
  });

  // Network
  link.on('Network.requestWillBeSent', (p) => {
    write('network', 'request', { id: p.requestId, method: p.request.method, url: p.request.url });
  });

  link.on('Network.responseReceived', (p) => {
    write('network', 'response', { id: p.requestId, status: p.response.status, url: p.response.url });
  });

  link.on('Network.loadingFailed', (p) => {
    write('network', 'failed', { id: p.requestId, error: p.errorText });
  });

  // Page
  link.on('Page.frameNavigated', (p) => {
    if (!p.frame.parentId) write('page', 'navigated', { url: p.frame.url });
  });

  link.on('Page.loadEventFired', () => {
    write('page', 'loaded', {});
  });

  // Report output path
  console.log(JSON.stringify({ ok: true, outputPath, pid: process.pid }));

  // Keep alive
  process.on('SIGTERM', () => { cleanup(); process.exit(0); });
  process.on('SIGINT', () => { cleanup(); process.exit(0); });
}

// ---------------------------------------------------------------------------
// Command: capture
// ---------------------------------------------------------------------------

async function handleCapture() {
  const port = parseInt(args.port);
  if (!port) fail('args', '--port is required for capture command');

  const captureType = args.type || 'url';
  const link = await ChromeLink.attach(port);

  try {
    switch (captureType) {
      case 'dom': {
        const result = await link.send('Runtime.evaluate', {
          expression: 'document.documentElement.outerHTML',
          returnByValue: true,
        });
        ok({ type: 'dom', html: result.result.value });
        break;
      }
      case 'screenshot': {
        const result = await link.send('Page.captureScreenshot', { format: 'png' });
        if (args.save) {
          fs.writeFileSync(args.save, Buffer.from(result.data, 'base64'));
          ok({ type: 'screenshot', saved: args.save });
        } else {
          ok({ type: 'screenshot', dataBase64: result.data });
        }
        break;
      }
      case 'metrics': {
        await link.send('Performance.enable');
        const result = await link.send('Performance.getMetrics');
        const metrics = {};
        for (const m of result.metrics) metrics[m.name] = m.value;
        ok({ type: 'metrics', metrics });
        break;
      }
      case 'url': {
        const result = await link.send('Runtime.evaluate', {
          expression: 'window.location.href',
          returnByValue: true,
        });
        ok({ type: 'url', url: result.result.value });
        break;
      }
      default:
        fail('args', `Unknown capture type: ${captureType}. Use: dom, screenshot, metrics, url`);
    }
  } finally {
    link.close();
  }
}

// ---------------------------------------------------------------------------
// Command: run
// ---------------------------------------------------------------------------

async function handleRun() {
  const port = parseInt(args.port);
  if (!port) fail('args', '--port is required for run command');

  const actionType = args.type;
  if (!actionType) fail('args', '--type is required for run command');

  const link = await ChromeLink.attach(port);

  // Enable Page domain so page lifecycle events (loadEventFired, frameNavigated) fire
  await link.send('Page.enable');

  try {
    switch (actionType) {
      case 'navigate': {
        const url = args.url;
        if (!url) fail('args', '--url is required for navigate action');
        // Register load listener BEFORE navigating to avoid race condition
        // where fast navigations (about:blank, cached) fire before listener is attached
        let didLoad = false;
        const loaded = new Promise((resolve) => {
          link.on('Page.loadEventFired', () => { didLoad = true; resolve(); });
          setTimeout(resolve, 10000);
        });
        await link.send('Page.navigate', { url });
        await loaded;
        ok({ action: 'navigate', url, timedOut: !didLoad });
        break;
      }
      case 'click': {
        const x = parseInt(args.x);
        const y = parseInt(args.y);
        if (isNaN(x) || isNaN(y)) fail('args', '--x and --y are required for click action');
        await link.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
        await link.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
        ok({ action: 'click', x, y });
        break;
      }
      case 'type': {
        const text = args.text;
        if (!text) fail('args', '--text is required for type action');
        for (const char of text) {
          await link.send('Input.dispatchKeyEvent', { type: 'keyDown', text: char });
          await link.send('Input.dispatchKeyEvent', { type: 'keyUp' });
        }
        ok({ action: 'type', length: text.length });
        break;
      }
      case 'focus': {
        const selector = args.selector;
        if (!selector) fail('args', '--selector is required for focus action');
        await link.send('Runtime.evaluate', {
          expression: `document.querySelector(${JSON.stringify(selector)})?.focus()`,
        });
        ok({ action: 'focus', selector });
        break;
      }
      case 'click-selector': {
        const selector = args.selector;
        if (!selector) fail('args', '--selector is required for click-selector action');
        const result = await link.send('Runtime.evaluate', {
          expression: `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return { found: false }; el.click(); return { found: true }; })()`,
          returnByValue: true,
        });
        const found = result.result.value?.found ?? false;
        if (!found) fail('element', `No element found for selector: ${selector}`);
        ok({ action: 'click-selector', selector });
        break;
      }
      case 'evaluate': {
        const expr = args.expr;
        if (!expr) fail('args', '--expr is required for evaluate action');
        const result = await link.send('Runtime.evaluate', {
          expression: expr,
          returnByValue: true,
          awaitPromise: true,
        });
        if (result.exceptionDetails) {
          fail('evaluate', result.exceptionDetails.text);
        } else {
          ok({ action: 'evaluate', value: result.result.value });
        }
        break;
      }
      default:
        fail('args', `Unknown action type: ${actionType}. Use: navigate, click, click-selector, type, focus, evaluate`);
    }
  } finally {
    link.close();
  }
}

// ---------------------------------------------------------------------------
// Command: teardown
// ---------------------------------------------------------------------------

async function handleTeardown() {
  const errors = [];

  // Kill Chrome
  if (args.pid) {
    const pid = parseInt(args.pid);
    try {
      process.kill(pid, 'SIGTERM');
      // Give it a moment to exit gracefully
      for (let i = 0; i < 10; i++) {
        try { process.kill(pid, 0); await pause(300); }
        catch { break; } // Process is gone
      }
      // Force kill if still alive
      try { process.kill(pid, 'SIGKILL'); } catch { /* already dead */ }
    } catch (e) {
      errors.push(`Chrome PID ${pid}: ${e.message}`);
    }
  }

  // Kill stream process
  if (args.stream) {
    const streamPid = parseInt(args.stream);
    try { process.kill(streamPid, 'SIGTERM'); }
    catch (e) { errors.push(`Stream PID ${streamPid}: ${e.message}`); }
  }

  // Remove temp profile directory
  if (args.profile) {
    try { fs.rmSync(args.profile, { recursive: true, force: true }); }
    catch (e) { errors.push(`Profile dir: ${e.message}`); }
  }

  // Remove JSONL file
  if (args.output) {
    try { fs.unlinkSync(args.output); }
    catch (e) { errors.push(`JSONL file: ${e.message}`); }
  }

  if (errors.length) {
    ok({ cleaned: true, warnings: errors });
  } else {
    ok({ cleaned: true });
  }
}

// ---------------------------------------------------------------------------
// Command registry + main
// ---------------------------------------------------------------------------

const commands = {
  launch: handleLaunch,
  stream: handleStream,
  capture: handleCapture,
  run: handleRun,
  teardown: handleTeardown,
};

async function main() {
  if (!command || !commands[command]) {
    const available = Object.keys(commands).join(', ');
    fail('usage', `Usage: cdp-bridge.js <${available}> [options]`);
  }

  try {
    await commands[command]();
  } catch (e) {
    fail('error', e.message);
  }
}

main();
