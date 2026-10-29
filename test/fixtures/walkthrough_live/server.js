// A tiny login fixture for the live walkthrough browser test. GET /login
// serves a form; POST /login checks the password against FIXTURE_PASSWORD,
// sets a session cookie, and redirects to /app. /app is gated on that
// cookie, shows a once-per-session tour unless sessionStorage says it was
// seen, and echoes a localStorage value the login page wrote.
const http = require("http");
const password = process.env.FIXTURE_PASSWORD;
const page = (body) => `<!doctype html><html><head><meta charset="utf-8"><title>fixture</title>
<style>body{font:16px sans-serif;margin:40px;background:#fff;color:#111}input,button{font:inherit;padding:8px;margin:4px}</style>
</head><body>${body}</body></html>`;
const login = page(`<form method="post" action="/login" id="login">
<label>Email <input id="email" name="email" type="email"></label>
<label>Password <input id="password" name="password" type="password"></label>
<button id="sign-in" type="submit">Sign in</button></form>
<script>document.getElementById("login").addEventListener("submit", () => {
  localStorage.setItem("member", document.getElementById("email").value);
});</script>`);
const app = page(`<h1 id="welcome">Welcome back</h1>
<p>Member: <span id="member"></span></p>
<div id="tour" role="dialog" hidden>Take the tour</div>
<p id="flag"></p>
<script>
document.getElementById("member").textContent = localStorage.getItem("member") || "none";
if (!sessionStorage.getItem("tour_seen")) document.getElementById("tour").hidden = false;
document.getElementById("flag").textContent = localStorage.getItem("seeded") || "unseeded";
</script>`);
http.createServer((req, res) => {
  const cookie = req.headers.cookie || "";
  if (req.method === "POST" && req.url === "/login") {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      const form = new URLSearchParams(body);
      if (form.get("password") === password) {
        res.writeHead(302, { "Set-Cookie": "sid=member-ok; Path=/; HttpOnly", Location: "/app" });
      } else {
        res.writeHead(302, { Location: "/login" });
      }
      res.end();
    });
    return;
  }
  if (req.url === "/app") {
    if (!cookie.includes("sid=member-ok")) { res.writeHead(302, { Location: "/login" }); res.end(); return; }
    res.writeHead(200, { "Content-Type": "text/html" }); res.end(app); return;
  }
  if (req.url === "/login") { res.writeHead(200, { "Content-Type": "text/html" }); res.end(login); return; }
  res.writeHead(404); res.end("not found");
}).listen(8080, "0.0.0.0");
