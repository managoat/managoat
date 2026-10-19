import { test } from "node:test";
import assert from "node:assert/strict";
import {
  Managoat,
  ManagoatError,
  NotFoundError,
  ResolutionError,
  ValidationError,
  WorkspaceFailedError,
  type AccountEvent,
  type Workspace,
  type WorkspaceField,
  type WorkspaceSetupEvent,
  type WorkspaceSetupLog,
  type WorkspaceSetupStepName,
  type WorkspaceStatusEvent,
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
  revision: "99999999-1111-1111-1111-111111111111",
  built_from_revision: status === "ready" ? "99999999-1111-1111-1111-111111111111" : null,
  stale: false,
  changed_fields: [],
  setup_step: null,
  inserted_at: "2026-10-18T00:00:00Z",
  updated_at: "2026-10-18T00:00:00Z",
  ...extra,
});

const setupLog: WorkspaceSetupLog = {
  workspace_id: WS,
  sandbox_id: "cccccccc-1111-1111-1111-111111111111",
  status: "failed",
  step: "setup_script",
  started_at: "2026-10-19T00:00:00Z",
  finished_at: "2026-10-19T00:01:00Z",
  steps: [
    {
      step: "machine",
      status: "succeeded",
      started_at: "2026-10-19T00:00:00Z",
      finished_at: "2026-10-19T00:00:05Z",
      output: "",
      omitted_lines: 0,
      omitted_bytes: 0,
    },
    {
      step: "setup_script",
      status: "failed",
      started_at: "2026-10-19T00:00:05Z",
      finished_at: "2026-10-19T00:01:00Z",
      output: "npm ERR! missing script: build\n",
      omitted_lines: 3,
      omitted_bytes: 120,
    },
  ],
};

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
    if (method === "POST" && url.pathname === `/api/workspaces/${WS}/rebuild`) {
      if (!(body as Record<string, unknown>).interrupt)
        return json(409, {
          error: "turns_running",
          message: "a conversation in this workspace is running a turn",
          conversation_ids: ["conv-1"],
        });
      return json(202, { data: workspace("provisioning") });
    }
    if (method === "POST" && url.pathname === `/api/workspaces/${WS}/retry`) {
      const next = reads[Math.min(read, reads.length - 1)]!;
      if (next === "failed") return json(202, { data: workspace("provisioning") });
      return json(409, {
        error: "workspace_not_failed",
        message: "the workspace is already being set up; follow its status until it is ready or failed",
      });
    }
    if (method === "GET" && url.pathname === `/api/workspaces/${WS}/setup-log`) return json(200, { data: setupLog });
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
  // A prefix never picks a workspace: landing in the wrong one is landing in
  // someone else's trust boundary.
  await assert.rejects(c.workspaces.get("monorepo"), ResolutionError);
  await assert.rejects(c.run("go", { agent: "reposage", workspace: "monorepo" }), ResolutionError);
});

test("rebuild posts interrupt only when asked, and a running turn is code turns_running", async () => {
  const seen: Seen[] = [];
  const c = client(seen);
  const error = await c.workspaces.rebuild("monorepo-box").catch((e: unknown) => e);
  assert.ok(error instanceof ManagoatError);
  assert.equal(error.status, 409);
  assert.equal(error.code, "turns_running");
  assert.deepEqual((error.body as { conversation_ids: string[] }).conversation_ids, ["conv-1"]);

  const rebuilt = await c.workspaces.rebuild(WS, { interrupt: true });
  assert.equal(rebuilt.status, "provisioning");
  const posts = seen.filter((s) => s.method === "POST");
  assert.deepEqual(
    posts.map((s) => [s.path, s.body]),
    [
      [`/api/workspaces/${WS}/rebuild`, {}],
      [`/api/workspaces/${WS}/rebuild`, { interrupt: true }],
    ],
  );
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

test("retry posts to the workspace's retry route and comes back provisioning", async () => {
  const seen: Seen[] = [];
  const retried = await client(seen, ["failed"]).workspaces.retry("monorepo-box");
  assert.equal(retried.status, "provisioning");
  const post = seen.find((s) => s.method === "POST");
  assert.deepEqual(post && { path: post.path, body: post.body }, {
    path: `/api/workspaces/${WS}/retry`,
    body: undefined,
  });
});

test("retry of a workspace that is not failed is a ManagoatError workspace_not_failed", async () => {
  const error = await client([], ["provisioning"]).workspaces.retry(WS).catch((e: unknown) => e);
  assert.ok(error instanceof ManagoatError);
  assert.equal(error.status, 409);
  assert.equal(error.code, "workspace_not_failed");
  assert.equal(error.retryable, false);
  assert.match(error.message, /already being set up/);
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

test("a sandbox key's refusal is code insufficient_scope, with the scope it needs", async () => {
  // The body the server sends a sandbox's own key on every workspace route.
  const body = {
    error: "insufficient_scope",
    message: "A sandbox key reaches only its own conversation tree and the inputs to spawn",
    reason: "insufficient_scope",
    required_scope: "full",
  };
  const fetch = async (): Promise<Response> =>
    new Response(JSON.stringify(body), { status: 403, headers: { "content-type": "application/json" } });
  const c = new Managoat({ baseUrl: "https://managoat.test", apiKey: "fk_test", fetch });

  const error = await c.workspaces.list().catch((e: unknown) => e);
  assert.ok(error instanceof ManagoatError);
  assert.equal(error.status, 403);
  assert.equal(error.code, "insufficient_scope");
  assert.equal(error.retryable, false);
  assert.match(error.message, /only its own conversation tree/);
  assert.equal((error.body as typeof body).required_scope, "full");
});

test("setupLog reads the last setup's log by name or id", async () => {
  const seen: Seen[] = [];
  const log = await client(seen).workspaces.setupLog("monorepo-box");
  assert.deepEqual(log, setupLog);
  assert.equal(seen.at(-1)?.path, `/api/workspaces/${WS}/setup-log`);
  const failed = log?.steps.find((s) => s.status === "failed");
  const step: WorkspaceSetupStepName | undefined = failed?.step;
  assert.equal(step, "setup_script");
});

test("setupLog is null when no setup has been kept", async () => {
  const fetch = async (): Promise<Response> =>
    new Response(JSON.stringify({ data: null }), { status: 200, headers: { "content-type": "application/json" } });
  const c = new Managoat({ baseUrl: "https://managoat.test", apiKey: "fk_test", fetch });
  assert.equal(await c.workspaces.setupLog(WS), null);
});

test("events() yields workspace.setup frames as their own kind", async () => {
  const frame = {
    workspace_id: WS,
    sandbox_id: "cccccccc-1111-1111-1111-111111111111",
    step: "packages",
    status: "running",
    lines: ["Reading package lists...", "Setting up jq (1.7)"],
    omitted_lines: 0,
    at: "2026-10-19T00:00:01Z",
  };
  const fetch = async (): Promise<Response> =>
    new Response(`event: workspace.setup\ndata: ${JSON.stringify(frame)}\n\n`, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  const c = new Managoat({ baseUrl: "https://managoat.test", apiKey: "fk_test", fetch });

  const frames: WorkspaceSetupEvent[] = [];
  for await (const event of c.events({ wait: false })) {
    if (event.kind === "workspace.setup") frames.push(event);
  }
  assert.deepEqual(frames, [{ ...frame, kind: "workspace.setup" }]);
  assert.deepEqual(frames[0]!.lines, ["Reading package lists...", "Setting up jq (1.7)"]);
});

test("events() yields workspace.status and conversations notices as their own kinds", async () => {
  const stage = { conversation_id: "conv-1", kind: "stage", stage: "turn", state: "done", ts: "2026-10-19T00:00:00Z" };
  const status = {
    workspace_id: WS,
    name: "monorepo-box",
    status: "ready",
    error: null,
    revision: "99999999-2222-2222-2222-222222222222",
    built_from_revision: "99999999-1111-1111-1111-111111111111",
    stale: true,
    changed_fields: ["setup_script", "env_vars"],
  };
  const frames = [
    `id: 5\nevent: stage\ndata: ${JSON.stringify(stage)}\n\n`,
    `event: workspace.status\ndata: ${JSON.stringify(status)}\n\n`,
    `event: conversations\ndata: ${JSON.stringify({ reason: "changed" })}\n\n`,
  ];
  let path = "";
  const fetch = async (input: string | URL | Request): Promise<Response> => {
    path = new URL(String(input)).pathname;
    return new Response(frames.join(""), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  const c = new Managoat({ baseUrl: "https://managoat.test", apiKey: "fk_test", fetch });

  const seen: AccountEvent[] = [];
  for await (const event of c.events({ wait: false })) seen.push(event);
  assert.equal(path, "/api/events/stream");
  assert.deepEqual(
    seen.map((e) => e.kind),
    ["stage", "workspace.status", "conversations"],
  );

  // Narrowing on `kind` reaches each frame's own fields, which a LogEvent
  // does not have.
  const statuses: WorkspaceStatusEvent[] = [];
  for (const event of seen) {
    if (event.kind === "workspace.status") statuses.push(event);
    else if (event.kind === "conversations") assert.equal(event.reason, "changed");
    else if (event.kind === "workspace.setup") assert.fail("no setup frame was sent");
    else {
      assert.equal(event.id, 5);
      assert.equal(event.conversation_id, "conv-1");
    }
  }
  assert.deepEqual(statuses, [{ ...status, kind: "workspace.status" }]);
  // Whether its machine is behind its environment, by field name (#2987).
  const changed: WorkspaceField[] = statuses[0]!.changed_fields;
  assert.equal(statuses[0]!.stale, true);
  assert.deepEqual(changed, ["setup_script", "env_vars"]);
  // A notice carries no event id, so it never moves the reconnect cursor.
  assert.equal("id" in seen[1]!, false);
});
