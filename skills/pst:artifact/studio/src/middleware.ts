import { defineMiddleware } from "astro:middleware";
import { loadThreads, saveThreads, type Thread } from "./lib/feedback";

// Dev-only comment round-trip. `astro dev` runs middleware for every request,
// so we can serve a tiny /api/comments endpoint here WITHOUT an SSR adapter -
// the published static build never runs this. GET returns saved threads; POST
// writes studio/feedback/<id>.json, which `/pst:artifact --feedback <id>` reads back
// to revise the plan. In production (import.meta.env.DEV === false) it no-ops.
export const onRequest = defineMiddleware(async (context, next) => {
  if (!import.meta.env.DEV || context.url.pathname !== "/api/comments") {
    return next();
  }

  const json = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), {
      status,
      headers: {
        "content-type": "application/json",
        "cache-control": "no-store",
      },
    });

  const id = (context.url.searchParams.get("id") ?? "").trim();
  if (!id) return json({ error: "missing id" }, 400);

  if (context.request.method === "GET") {
    return json({ id, threads: loadThreads(id) });
  }

  if (context.request.method === "POST") {
    try {
      const body = (await context.request.json()) as { threads?: Thread[] };
      const threads = Array.isArray(body.threads) ? body.threads : [];
      saveThreads(id, threads);
      return json({ ok: true, id, count: threads.length });
    } catch {
      return json({ error: "bad payload" }, 400);
    }
  }

  return json({ error: "method not allowed" }, 405);
});
