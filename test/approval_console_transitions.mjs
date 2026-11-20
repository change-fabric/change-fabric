// Behaviour scenarios for the approval console page script, run as a
// browserless /function module by approval_console_transitions_test.rb, which
// prepends `globalThis.PREVIEW_URL = "..."` and asserts on the returned
// snapshots. Each scenario loads the real page (no fragment) from the preview
// renderer in a fresh page, after stubbing the passkey and the approve POST
// from outside the page: the page script has no test mode.
const LIFETIME_MS = 15 * 60 * 1000;

const SCENARIOS = {
  // state-transition table: pending, code complete
  code_complete: { type: "12a4b5678", click: false },
  code_incomplete: { type: "12345", click: false },
  countdown: { click: false },
  // waiting for passkey: the stubbed get never settles
  waiting: { type: "482913", click: true, hang: true, settle: "waiting" },
  wrong_code: { type: "482913", click: true, status: 401, body: { error: "totp_invalid" } },
  assertion_failure: { type: "482913", click: true, status: 401, body: { error: "assertion_invalid" } },
  lock: { type: "482913", click: true, status: 423, body: { error: "locked", locked_until: "2026-11-20T21:58:00Z" } },
  busy: { type: "482913", click: true, status: 503, body: { error: "busy" } },
  other_refusal: { type: "482913", click: true, status: 500, body: { error: "boom" } },
  expiry_server: { type: "482913", click: true, status: 410, body: { error: "expired" } },
  expiry_client: { click: false, shiftMs: LIFETIME_MS + 61000 },
  expiring_now: { click: false, shiftMs: LIFETIME_MS + 30000 },
  success: { type: "482913", click: true, status: 200, body: { proof: { kind: "stub" } } },
  approved_elsewhere: { type: "482913", click: true, status: 409, body: { error: "not_pending" } },
  passkey_cancelled: { type: "482913", click: true, cancel: true },
  passkey_unsupported: { click: false, noPasskey: true }
};

async function snapshot(page) {
  return page.evaluate(() => {
    const $ = (id) => document.getElementById(id);
    return {
      result_hidden: $("result").hidden,
      result_kind: $("result").dataset.kind,
      result_big: $("result-big").textContent,
      result_sub: $("result-sub").textContent,
      msg: $("msg") ? $("msg").textContent : null,
      form: !!$("approve"),
      away: !!$("away"),
      countdown: $("countdown") ? $("countdown").textContent : null,
      totp_value: $("totp") ? $("totp").value : null,
      totp_disabled: $("totp") ? $("totp").disabled : null,
      go_disabled: $("go") ? $("go").disabled : null,
      go_focused: document.activeElement === $("go"),
      has_bar: document.body.classList.contains("has-bar"),
      what_changes: document.querySelector(".changes").textContent,
      calls: window.__calls || []
    };
  });
}

async function runScenario(browser, cfg) {
  const page = await browser.newPage();
  await page.setViewport({ width: 390, height: 844 });
  await page.evaluateOnNewDocument((c) => {
    window.__calls = [];
    const buf = () => new ArrayBuffer(4);
    const get = async () => {
      if (c.hang) return new Promise(() => {});
      if (c.cancel) throw new DOMException("cancelled", "NotAllowedError");
      return { rawId: buf(), response: { authenticatorData: buf(), clientDataJSON: buf(), signature: buf() } };
    };
    Object.defineProperty(navigator, "credentials", { value: { get }, configurable: true });
    window.fetch = async (url, opts) => {
      window.__calls.push({ url: String(url), body: opts && opts.body });
      return new Response(JSON.stringify(c.body || {}), { status: c.status || 200, headers: { "content-type": "application/json" } });
    };
    if (c.shiftMs) {
      const real = Date.now;
      Date.now = () => real() + c.shiftMs;
    }
    if (c.noPasskey) window.PublicKeyCredential = undefined;
    else if (!window.PublicKeyCredential) window.PublicKeyCredential = function () {};
  }, cfg);
  await page.goto(`${globalThis.PREVIEW_URL}/type/carve-out/state/pending`, { waitUntil: "load" });
  if (cfg.type) await page.type("#totp", cfg.type);
  if (cfg.click) await page.click("#go");
  if (cfg.settle === "waiting") {
    await page.waitForFunction(() => document.getElementById("msg").textContent === "Waiting for your passkey", { timeout: 8000 });
  } else if (cfg.click) {
    await page.waitForFunction(() => {
      const r = document.getElementById("result");
      const m = document.getElementById("msg");
      return !r.hidden || (m && m.textContent && m.textContent !== "Waiting for your passkey");
    }, { timeout: 8000 });
  } else if (cfg.shiftMs && cfg.shiftMs > LIFETIME_MS + 60000) {
    await page.waitForFunction(() => !document.getElementById("result").hidden, { timeout: 8000 });
  }
  const shot = await snapshot(page);
  await page.close();
  return shot;
}

export default async function ({ page }) {
  const browser = page.browser();
  const out = {};
  for (const [name, cfg] of Object.entries(SCENARIOS)) {
    try {
      out[name] = await runScenario(browser, cfg);
    } catch (error) {
      out[name] = { error: String(error && error.message ? error.message : error) };
    }
  }
  return { data: out, type: "application/json" };
}
