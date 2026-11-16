# frozen_string_literal: true

require 'cgi'
require 'json'

module SecretIntake
  # The one-field upload page. Self-contained: inline styles and script, no
  # external fetch except the PUT to the embedded signed URL, which is the same
  # S3 origin the page is served from. The body goes up as text/plain.
  class PageRenderer
    def render(put_url:, name:, expires_at:)
      TEMPLATE
        .sub('__NAME__') { CGI.escapeHTML(name) }
        .sub('__EXPIRES__') { CGI.escapeHTML(expires_at.utc.strftime('%Y-%m-%d %H:%M UTC')) }
        .sub('__PUT_URL__') { JSON.generate(put_url).gsub('</', '<\/') }
    end

    TEMPLATE = <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="referrer" content="no-referrer">
      <meta name="robots" content="noindex">
      <title>Secret intake</title>
      <style>
      :root { --bg:#f7f5f0; --fg:#1d1a22; --muted:#55505c; --line:#cfc8bd; --accent:#4b3f8f; --on-accent:#ffffff; --ok:#2f6b3e; --err:#9b2c2c; }
      @media (prefers-color-scheme: dark) { :root { --bg:#16131b; --fg:#f2eee6; --muted:#c3bcc9; --line:#3c3546; --accent:#b9adf2; --on-accent:#16131b; --ok:#9ccaa8; --err:#f0a3a3; } }
      * { box-sizing: border-box; }
      body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.5 -apple-system, system-ui, sans-serif; }
      main { max-width:440px; margin:0 auto; padding:32px 16px; }
      h1 { font-size:22px; margin:0 0 8px; }
      p { color:var(--muted); margin:0 0 20px; }
      label { display:block; font-weight:600; margin:16px 0 6px; overflow-wrap:anywhere; }
      input { width:100%; padding:12px; font:inherit; color:var(--fg); background:transparent; border:1px solid var(--line); border-radius:6px; }
      button { margin-top:24px; width:100%; padding:14px; font:inherit; font-weight:600; color:var(--on-accent); background:var(--accent); border:0; border-radius:6px; }
      button:disabled { opacity:.5; }
      #status { margin-top:16px; min-height:1.5em; }
      .ok { color:var(--ok); } .err { color:var(--err); }
      </style>
      </head>
      <body>
      <main>
      <h1>Send a secret</h1>
      <p>Upload only: this page cannot read anything back. It stops working at __EXPIRES__.</p>
      <form id="f" autocomplete="off">
      <label for="secret">__NAME__</label>
      <input id="secret" type="password" required autocomplete="off" spellcheck="false" autocapitalize="off">
      <button id="send" type="submit">Send</button>
      <div id="status" role="status" aria-live="polite"></div>
      </form>
      </main>
      <script>
      const PUT_URL = __PUT_URL__;
      const f = document.getElementById("f"), s = document.getElementById("status"), b = document.getElementById("send");
      f.addEventListener("submit", async (e) => {
        e.preventDefault();
        const value = document.getElementById("secret").value.trim();
        if (!value) return;
        b.disabled = true; s.className = ""; s.textContent = "Sending";
        try {
          const r = await fetch(PUT_URL, { method: "PUT", headers: { "Content-Type": "text/plain" }, body: value });
          if (!r.ok) throw new Error("HTTP " + r.status);
          f.reset(); s.className = "ok"; s.textContent = "Sent. You can close this page.";
        } catch (err) {
          s.className = "err"; s.textContent = "Upload failed (" + err.message + "). Try again or ask for a new link."; b.disabled = false;
        }
      });
      </script>
      </body>
      </html>
    HTML
  end
end
