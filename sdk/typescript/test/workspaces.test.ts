import { test } from "node:test";
import assert from "node:assert/strict";
import {
  Managoat,
  ManagoatError,
  NotFoundError,
  ResolutionError,
  ValidationError,
  WorkspaceFailedError,
  type Workspace,
} from "../src/index.ts";

const ENV = "bbbbbbbb-1111-1111-1111-111111111111";
const VAULT = "aaaaaaaa-1111-1111-1111-111111111111";
const AGENT = "11111111-1111-1111-1111-111111111111";
const WS = "dddddddd-1111-1111-1111-111111111111";

const workspace = (status: Workspace["status"], extra: Partial<Workspace> = {}): Workspace => ({
  id: WS,
  name: "monorepo-box",
  implicit: false,
  environment_id: ENV,
  vault_id: VAULT,
  sandbox_provider: "sprites",
  status,
  error: null,
  sandbox_id: status === "ready" ? "cccccccc-1111-1111-1111-111111111111" : null,
  sandbox_status: status === "ready" ? "ready" : null,
  inserted_at: "2026-10-18T00:00:00Z",
  updated_at: "2026-10-18T00:00:00Z",
  ...extra,
});

type Seen = { method: string; path: string; query: URLSearchParams; body: unknown };

/**
 * A fake of the workspace routes, as the server answers them: `{data: …}`
 * on every one but DELETE (204). `reads` scripts GET /api/workspaces/:id in
 * order, the last repeating; a number is an error status to answer with.
 */
function client(seen: Seen[], reads: (Workspace["status"] | number)[] = ["ready"]): Managoat {
  let read = 0;
  const fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    seen.push({ method, path: url.pathname, query: url.searchParams, body });
    const json = (status: number, payload: unknown) =>
      new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });

    if (method === "GET" && url.pathname === "/api/agents")
      return json(200, { data: [{ id: AGENT, name: "reposage", runtime: "claude" }] });
    if (method === "GET" && url.pathname === "/api/workspaces")
      return json(200, {
        data: [
          workspace("ready"),
          { ...workspace("ready"), id: "eeeeeeee-1111-1111-1111-111111111111", name: "twin" },
          { ...workspace("ready"), id: "ffffffff-1111-1111-1111-111111111111", name: "twin" },
        ],
      });
    if (method === "POST" && url.pathname === "/api/workspaces") return json(201, { data: workspace("provisioning") });
    if (method === "GET" && url.pathname === `/api/workspaces/${WS}`) {
      const next = reads[Math.min(read++, reads.length - 1)]!;
      if (typeof next === "number") return json(next, { error: "bad_gateway" });
      return json(200, {
        data: workspace(next, next === "failed" ? { error: "setup script exited 1: missing script: build" } : {}),
      });
    }
    if (method === "DELETE" && url.pathname === `/api/workspaces/${WS}`) return new Response(null, { status: 204 });
    if (method === "GET" && url.pathname.startsWith(`/api/workspaces/${WS}/`))
      return json(200, { data: { path: "/home/sprite", entries: [], truncated: false } });
    if (method === "POST" && url.pathname === "/api/conversations") {
      if ((body as Record<string, unknown>).environment_id)
        return json(422, {
          error: "workspace_fixes_environment",
          message: "the workspace fixes the environment and vault its conversations run with",
        });
      return json(201, { data: { id: "conv-1", status: "idle", agent_id: AGENT } });
    }
    return json(404, { error: "not_found" });
  };
  return new Managoat({ baseUrl: "https://managoat.test", apiKey: "fk_test", fetch });
}

test("create sends the API's shape and comes back provisioning", async () => {
  const seen: Seen[] = [];
  const created = await client(seen).workspaces.create({
    name: "monorepo-box",
    environment_id: ENV,
    vault_id: VAULT,
  });
  assert.equal(created.status, "provisioning");
  assert.deepEqual(seen[0], {
    method: "POST",
    path: "/api/workspaces",
    query: new URLSearchParams(),
    body: { name: "monorepo-box", environment_id: ENV, vault_id: VAULT },
  });
});

test("list leaves implicit workspaces out unless asked", async () => {
  const seen: Seen[] = [];
  const c = client(seen);
  await c.workspaces.list();
  await c.workspaces.list({ implicit: true });
  assert.equal(seen[0]?.query.has("implicit"), false);
  assert.equal(seen[1]?.query.get("implicit"), "true");
});

test("get and delete take a name or an id; an ambiguous name says so", async () => {
  const seen: Seen[] = [];
  const c = client(seen);
  assert.equal((await c.workspaces.get("monorepo-box")).id, WS);
  await c.workspaces.delete(WS);
  assert.deepEqual(
    seen.filter((s) => s.method === "DELETE").map((s) => s.path),
    [`/api/workspaces/${WS}`],
  );
  await assert.rejects(c.workspaces.get("twin"), ResolutionError);
});

test("waitForReady follows provisioning to ready, reporting each change once", async () => {
  const seen: Seen[] = [];
  const statuses: string[] = [];
  const ready = await client(seen, ["provisioning", "provisioning", "ready"]).workspaces.waitForReady(WS, {
    intervalMs: 1,
    onStatus: (w) => statuses.push(w.status),
  });
  assert.equal(ready.status, "ready");
  assert.deepEqual(statuses, ["provisioning", "ready"]);
  assert.equal(seen.filter((s) => s.path === `/api/workspaces/${WS}`).length, 3);
});

test("waitForReady throws WorkspaceFailedError with the workspace's own error", async () => {
  const error = await client([], ["provisioning", "failed"])
    .workspaces.waitForReady(WS, { intervalMs: 1 })
    .catch((e: unknown) => e);
  assert.ok(error instanceof WorkspaceFailedError);
  assert.equal(error.code, "workspace_failed");
  assert.match(error.message, /missing script: build/);
  assert.equal(error.workspace.status, "failed");
});

test("waitForReady retries a 5xx read, and gives up at its deadline", async () => {
  const ready = await client([], [502, 503, "ready"]).workspaces.waitForReady(WS, { intervalMs: 1 });
  assert.equal(ready.status, "ready");

  const timeout = await client([], ["provisioning"])
    .workspaces.waitForReady(WS, { intervalMs: 5, timeoutMs: 20 })
    .catch((e: unknown) => e);
  assert.ok(timeout instanceof ManagoatError);
  assert.equal(timeout.code, "timeout");
  assert.match(timeout.message, /still provisioning/);
});

test("waitForReady does not retry a 4xx", async () => {
  await assert.rejects(client([], [404]).workspaces.waitForReady(WS, { intervalMs: 1 }), NotFoundError);
});

test("the four disk reads address the workspace, with the API's query names", async () => {
  const seen: Seen[] = [];
  const c = client(seen);
  await c.workspaces.files(WS, "api");
  await c.workspaces.file(WS, "api/README.md", { maxBytes: 10 });
  await c.workspaces.gitStatus(WS, { path: "api", untracked: "all" });
  await c.workspaces.diff(WS, { path: "api", ref: "HEAD" });
  assert.deepEqual(
    seen.map((s) => s.path),
    ["files", "file", "git-status", "diff"].map((r) => `/api/workspaces/${WS}/${r}`),
  );
  assert.equal(seen[1]?.query.get("max_bytes"), "10");
  assert.equal(seen[2]?.query.get("untracked"), "all");
  assert.equal(seen[3]?.query.get("ref"), "HEAD");
  assert.equal(seen[3]?.query.has("staged"), false);
});

test("run launches into a workspace by name, in its own folder", async () => {
  const seen: Seen[] = [];
  const c = client(seen);
  const run = c.run("", { agent: "reposage", workspace: "monorepo-box", cwd: "/home/sprite/api" });
  await run.conversation;
  run.cancel();
  await run.catch(() => undefined);
  const launch = seen.find((s) => s.method === "POST" && s.path === "/api/conversations");
  assert.deepEqual(launch?.body, { agent_id: AGENT, workspace_id: WS, cwd: "/home/sprite/api" });
});

test("a launch naming another environment is the server's 422, as a ValidationError", async () => {
  const run = client([]).run("go", { agent: "reposage", workspace: WS, environment: ENV });
  const error = await run.catch((e: unknown) => e);
  assert.ok(error instanceof ValidationError);
  assert.equal(error.code, "workspace_fixes_environment");
});
