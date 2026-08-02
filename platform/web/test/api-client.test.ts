import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The one place that knows how this API reports a failure, and the two or three
 * places that build a request the server is picky about.
 *
 * These are the parts of src/api.ts that are decisions rather than plumbing: a
 * non-JSON edge response becoming a message instead of a parse crash, a 2xx that
 * did not carry what it promised, and the query and body shapes the API rejects
 * if they carry an empty value where it expected an absent one. Everything else
 * in that module is a one-line wrapper the verify/ runs already exercise against
 * the real server.
 */

const ORIGIN = "https://api.example.test";

type Api = typeof import("../src/api");

let api: Api;
let fetchMock: ReturnType<typeof vi.fn>;

/** Whatever the next request should get back. */
function answer(
  status: number,
  body: unknown,
  { json = true }: { json?: boolean } = {},
): void {
  fetchMock.mockResolvedValueOnce({
    ok: status >= 200 && status < 300,
    status,
    json: json
      ? async () => body
      : async () => {
          throw new SyntaxError("Unexpected token < in JSON at position 0");
        },
  });
}

/** The single call the mock recorded, as [url, init]. */
function lastCall(): [string, RequestInit] {
  return fetchMock.mock.calls.at(-1) as [string, RequestInit];
}

beforeEach(async () => {
  vi.resetModules();
  vi.stubEnv("VITE_API_ORIGIN", ORIGIN);
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
  api = await import("../src/api");
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("how a failure reaches the caller", () => {
  it("turns a non-JSON edge response into a message rather than a parse crash", async () => {
    // A CloudFront or API Gateway error page. The routes themselves always
    // answer JSON, so this only ever comes from in front of them.
    answer(502, "<html>502 Bad Gateway</html>", { json: false });

    await expect(api.listTeams()).rejects.toMatchObject({
      name: "Error",
      message: "the server answered 502 with no readable body",
      status: 502,
    });
  });

  it("carries the server's own error text when it sent one", async () => {
    answer(409, { error: "slug is already taken" });

    await expect(
      api.createTeam({ name: "Core", slug: "core" }),
    ).rejects.toMatchObject({ message: "slug is already taken", status: 409 });
  });

  it("falls back to the status when the body carried no error field", async () => {
    answer(403, { detail: "nope" });

    await expect(api.listTeams()).rejects.toMatchObject({
      message: "the server answered 403",
      status: 403,
    });
  });

  it("is an ApiError, so a caller can read the status without parsing the text", async () => {
    answer(401, { error: "not signed in" });

    const failure = await api.listTeams().catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(api.ApiError);
    expect((failure as InstanceType<Api["ApiError"]>).status).toBe(401);
  });

  it("reports a 2xx that did not carry an organization as a server fault", async () => {
    // The dashboard would otherwise render a blank organization and blame the
    // person who just typed a perfectly good name into onboarding.
    answer(201, { ok: true });

    await expect(
      api.createOrganization({
        organizationName: "Acme",
        organizationSlug: "acme",
      }),
    ).rejects.toMatchObject({
      message: "the server did not return an organization",
      status: 500,
    });
  });
});

describe("what goes on the wire", () => {
  it("sends the session cookie on every request", async () => {
    answer(200, { teams: [] });
    await api.listTeams();

    const [url, init] = lastCall();
    expect(url).toBe(`${ORIGIN}/v1/teams`);
    expect(init.credentials).toBe("include");
    expect(init.method).toBe("GET");
  });

  it("sets a JSON content type only when there is a body to describe", async () => {
    answer(200, { team: {} });
    await api.archiveTeam("team_1");

    const [url, init] = lastCall();
    expect(url).toBe(`${ORIGIN}/v1/teams/team_1/archive`);
    expect(init.method).toBe("POST");
    expect(init.headers).toBeUndefined();
    expect(init.body).toBeUndefined();
  });

  it("omits `before` from the artifact query rather than sending it empty", async () => {
    // The API reads `before` as a cursor. An empty one is not the same request
    // as no cursor at all, and the difference is a page of results.
    answer(200, { artifacts: [], nextCursor: null });
    await api.listArtifacts("team_1");
    expect(lastCall()[0]).toBe(`${ORIGIN}/v1/artifacts?teamId=team_1`);

    answer(200, { artifacts: [], nextCursor: null });
    await api.listArtifacts("team_1", "");
    expect(lastCall()[0]).toBe(`${ORIGIN}/v1/artifacts?teamId=team_1`);

    answer(200, { artifacts: [], nextCursor: null });
    await api.listArtifacts("team_1", null);
    expect(lastCall()[0]).toBe(`${ORIGIN}/v1/artifacts?teamId=team_1`);

    answer(200, { artifacts: [], nextCursor: null });
    await api.listArtifacts("team_1", "art_9");
    expect(lastCall()[0]).toBe(`${ORIGIN}/v1/artifacts?teamId=team_1&before=art_9`);
  });

  it("escapes a team id into the artifact query rather than concatenating it", async () => {
    answer(200, {
      teamId: "a/b",
      teamSlug: "core",
      organizationSlug: "acme",
      viewerPrefix: "/",
      expiresAt: "",
    });
    await api.authorizeViewer("a/b");

    expect(lastCall()[0]).toBe(`${ORIGIN}/v1/artifacts/authorize?teamId=a%2Fb`);
  });

  it("omits teamId from an invitation rather than sending an empty one", async () => {
    // An org-wide invitation and an invitation to a team named "" are different
    // requests, and only one of them is a thing the API will accept.
    answer(201, { invitation: {} });
    await api.createInvitation({ email: "who@example.test" });
    expect(JSON.parse(lastCall()[1].body as string)).toEqual({
      email: "who@example.test",
    });

    answer(201, { invitation: {} });
    await api.createInvitation({ email: "who@example.test", teamId: "" });
    expect(JSON.parse(lastCall()[1].body as string)).toEqual({
      email: "who@example.test",
    });

    answer(201, { invitation: {} });
    await api.createInvitation({ email: "who@example.test", teamId: "team_1" });
    expect(JSON.parse(lastCall()[1].body as string)).toEqual({
      email: "who@example.test",
      teamId: "team_1",
    });
  });

  it("returns the raw key alongside the row, because it is never sent again", async () => {
    answer(201, { key: "cfk_live_secret", apiKey: { id: "key_1" } });

    const minted = await api.mintKey("team_1", "ci");
    expect(minted.key).toBe("cfk_live_secret");
    expect(minted.apiKey.id).toBe("key_1");
    expect(JSON.parse(lastCall()[1].body as string)).toEqual({ name: "ci" });
  });
});
