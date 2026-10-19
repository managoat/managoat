import type { HttpClient } from "./http.ts";
import type { Resolver } from "./resolve.ts";
import type {
  Agent,
  AgentInput,
  AgentPatch,
  Environment,
  EnvironmentInput,
  EnvironmentPatch,
  McpConnection,
  McpConnectionInput,
  McpConnectionLogin,
  Secret,
  SandboxDiff,
  SandboxFile,
  SandboxListing,
  SandboxStatus,
  Vault,
  VaultInput,
  VaultPatch,
  VaultSecret,
  VaultSecretMetadataPatch,
  Workspace,
  WorkspaceInput,
} from "./types.ts";
import { ManagoatError, WorkspaceFailedError } from "./errors.ts";

/**
 * Payloads here use the API's own key names (`environment_id`, `mcp_servers`,
 * `allowed_vault_ids`) rather than camelCase. That is a choice, not an
 * oversight: an agent definition is the same object in the REST API, in a
 * `managoat.yml` manifest and here, so one definition reads identically in all
 * three and the API reference doubles as the SDK reference. Options that
 * control the SDK's own behaviour — `timeoutMs`, `signal` — are camelCase,
 * because those are not data.
 */

/**
 * List, read, define, change and delete one kind of thing.
 *
 * `Patch` is its own parameter rather than `Partial<Input>`: the API's update
 * schemas are not simply every create field made optional, and the generated
 * ones say so exactly.
 */
class Collection<T extends { id: string }, Input, Patch> {
  protected readonly http: HttpClient;
  protected readonly resolver: Resolver;
  protected readonly path: string;
  protected readonly what: string;

  constructor(http: HttpClient, resolver: Resolver, path: string, what: string) {
    this.http = http;
    this.resolver = resolver;
    this.path = path;
    this.what = what;
  }

  /** Everything on the account. */
  async list(search?: string): Promise<T[]> {
    return this.http.list<T>(this.path, { query: { search } });
  }

  /** One of them, by name or id. */
  async get(nameOrId: string): Promise<T> {
    const { id } = await this.resolver.resolve(this.path, this.what, nameOrId);
    return this.http.data<T>("GET", `${this.path}/${id}`);
  }

  /** Define a new one. */
  async create(input: Input): Promise<T> {
    const created = await this.http.data<T>("POST", this.path, { body: input });
    // A new name has to be findable by the next `run({ agent: "…" })`.
    this.resolver.forget(this.path);
    return created;
  }

  /** Change one. Only the fields you pass are touched. */
  async update(nameOrId: string, patch: Patch): Promise<T> {
    const { id } = await this.resolver.resolve(this.path, this.what, nameOrId);
    const updated = await this.http.data<T>("PATCH", `${this.path}/${id}`, { body: patch });
    // The patch may have renamed it.
    this.resolver.forget(this.path);
    return updated;
  }

  /** Delete one. */
  async delete(nameOrId: string): Promise<void> {
    const { id } = await this.resolver.resolve(this.path, this.what, nameOrId);
    await this.http.request("DELETE", `${this.path}/${id}`);
    this.resolver.forget(this.path);
  }
}

/**
 * Secrets on an environment or a vault.
 *
 * Values are write-only: `list` returns keys, never what they are worth. That
 * is the whole point — the SDK can put a credential into a sandbox and can
 * never read it back out.
 */
class Secrets {
  protected readonly http: HttpClient;
  private readonly resolver: Resolver;
  private readonly parentPath: string;
  private readonly what: string;

  constructor(http: HttpClient, resolver: Resolver, parentPath: string, what: string) {
    this.http = http;
    this.resolver = resolver;
    this.parentPath = parentPath;
    this.what = what;
  }

  /** The keys stored here. Never the values. */
  async list(parent: string): Promise<Secret[]> {
    return this.http.list<Secret>(`${await this.parentId(parent)}/secrets`);
  }

  /** Store a secret, or replace one with the same key. */
  async set(parent: string, key: string, value: string): Promise<Secret> {
    return this.http.data<Secret>("POST", `${await this.parentId(parent)}/secrets`, {
      body: { key, value },
    });
  }

  /** Store several at once. */
  async setAll(parent: string, secrets: Record<string, string>): Promise<Secret[]> {
    const base = await this.parentId(parent);
    const out: Secret[] = [];
    // Serially: these are audited writes, and a partial failure should say
    // which key it stopped on rather than leave a scattered half-write.
    for (const [key, value] of Object.entries(secrets)) {
      out.push(
        await this.http.data<Secret>("POST", `${base}/secrets`, { body: { key, value } }),
      );
    }
    return out;
  }

  /** Remove one, by key. */
  async delete(parent: string, key: string): Promise<void> {
    await this.http.request("DELETE", `${await this.parentId(parent)}/secrets/${encodeURIComponent(key)}`);
  }

  protected async parentId(nameOrId: string): Promise<string> {
    const { id } = await this.resolver.resolve(this.parentPath, this.what, nameOrId);
    return `${this.parentPath}/${id}`;
  }
}

/** Vault metadata can change without reading or replacing its secret value. */
class VaultSecrets extends Secrets {
  async update(parent: string, key: string, patch: VaultSecretMetadataPatch): Promise<VaultSecret> {
    return this.http.data<VaultSecret>(
      "PATCH", `${await this.parentId(parent)}/secrets/${encodeURIComponent(key)}`, { body: patch },
    );
  }
}

/** The agents on this account. */
export class Agents extends Collection<Agent, AgentInput, AgentPatch> {
  constructor(http: HttpClient, resolver: Resolver) {
    super(http, resolver, "/api/agents", "agent");
  }
}

/** The environments on this account, and their secrets. */
export class Environments extends Collection<Environment, EnvironmentInput, EnvironmentPatch> {
  readonly secrets: Secrets;

  constructor(http: HttpClient, resolver: Resolver) {
    super(http, resolver, "/api/environments", "environment");
    this.secrets = new Secrets(http, resolver, this.path, this.what);
  }
}

/** The vaults on this account, and their secrets. */
export class Vaults extends Collection<Vault, VaultInput, VaultPatch> {
  readonly secrets: VaultSecrets;

  constructor(http: HttpClient, resolver: Resolver) {
    super(http, resolver, "/api/vaults", "vault");
    this.secrets = new VaultSecrets(http, resolver, this.path, this.what);
  }
}

/**
 * Connections: the account's OAuth grants to remote MCP servers (ADR 0085).
 *
 * `create` returns a pending connection and an `authorize_url`. Open that URL
 * in a browser signed in to Managoat as the same account, within ten minutes;
 * the connection becomes `active` when the provider sends the browser back.
 * An agent then names it in an `mcp_servers` entry:
 * `{ type: "http", url, auth: { connection: id } }`. The token never leaves
 * the server: it reaches the MCP server through the egress broker.
 */
export class Connections {
  private readonly http: HttpClient;
  private readonly path = "/api/connections";

  constructor(http: HttpClient) {
    this.http = http;
  }

  /** Every connection on the account, newest first. */
  async list(): Promise<McpConnection[]> {
    return this.http.list<McpConnection>(this.path);
  }

  /** One connection, by id. */
  async get(id: string): Promise<McpConnection> {
    return this.http.request<McpConnection>("GET", `${this.path}/${encodeURIComponent(id)}`);
  }

  /** Discover, register and start a sign-in; open the returned `authorize_url`. */
  async create(input: McpConnectionInput): Promise<McpConnectionLogin> {
    return this.http.request<McpConnectionLogin>("POST", this.path, { body: input });
  }

  /** Start another sign-in on a connection; open the returned `authorize_url`. */
  async reconnect(id: string): Promise<McpConnectionLogin> {
    return this.http.request<McpConnectionLogin>(
      "POST", `${this.path}/${encodeURIComponent(id)}/authorize`,
    );
  }

  /** Disconnect: delete it, and revoke its grant at the provider. */
  async delete(id: string): Promise<void> {
    await this.http.request("DELETE", `${this.path}/${encodeURIComponent(id)}`);
  }
}

/** How `workspaces.waitForReady` waits. */
export interface WaitForReadyOptions {
  /** Give up after this many ms. Default 30 minutes, about a setup's own deadline. */
  timeoutMs?: number;
  /** How often to read the workspace, in ms. Default 2000. */
  intervalMs?: number;
  /** Stop waiting. The setup goes on at the server. */
  signal?: AbortSignal;
  /** Called with the workspace each time its status changes, the first read included. */
  onStatus?: (workspace: Workspace) => void;
}

/**
 * Workspaces (ADR 0097): machines the caller keeps. A workspace is set up once
 * from an environment and an optional vault, on create; then any agent is
 * launched into it with `run(prompt, { agent, workspace, cwd })`, each
 * conversation in a working directory and config home of its own. Its
 * environment, vault and provider are fixed for its life.
 *
 * **A workspace is one trust boundary.** Every conversation in it runs as
 * the same user on the same disk, so each can read the others' files,
 * config homes and tokens, and plant instructions or hooks the others then
 * follow. Launch without a workspace to give a conversation a sandbox of its
 * own.
 *
 * Its machine is parked when idle, like any sandbox, and woken by the next
 * prompt. The max-lifetime ceiling parks it rather than destroying it, so it
 * lives until you delete it or its provider loses it, and Managoat does not
 * cap how many you keep: delete the ones you are done with.
 *
 * A sandbox's own key (`MANAGOAT_TOKEN` inside a sandbox) cannot use any of
 * this: every call answers 403, and a conversation it starts gets a sandbox
 * of its own.
 */
export class Workspaces {
  private readonly http: HttpClient;
  private readonly resolver: Resolver;
  private readonly path = "/api/workspaces";

  constructor(http: HttpClient, resolver: Resolver) {
    this.http = http;
    this.resolver = resolver;
  }

  /**
   * The account's workspaces, newest first. `implicit: true` adds the
   * implicit ones: the sandbox of its own that each conversation launched
   * without a workspace gets, which ends with it.
   */
  async list(opts: { implicit?: boolean } = {}): Promise<Workspace[]> {
    return this.http.list<Workspace>(this.path, {
      query: { implicit: opts.implicit ? "true" : undefined },
    });
  }

  /** One workspace, by name or id. Names need not be unique; an ambiguous one throws. */
  async get(nameOrId: string): Promise<Workspace> {
    return this.http.data<Workspace>("GET", `${this.path}/${await this.id(nameOrId)}`);
  }

  /**
   * Create a workspace and start setting up its machine at once. It comes
   * back `provisioning`; `waitForReady` follows it to `ready` or `failed`.
   * Conversations may be launched into it before then, and their first
   * prompt waits for the setup. A full fleet is a `NotReadyError`
   * (`fleet_full`).
   */
  async create(input: WorkspaceInput): Promise<Workspace> {
    const created = await this.http.data<Workspace>("POST", this.path, { body: input });
    this.resolver.forget(this.path);
    return created;
  }

  /**
   * Delete a workspace: every live conversation in it is terminated (their
   * transcripts are kept) and its machine is destroyed with its disk. Not
   * refused while conversations are running. An implicit workspace is a
   * `NotFoundError` here; deleting its conversation is how it goes.
   */
  async delete(nameOrId: string): Promise<void> {
    await this.http.request("DELETE", `${this.path}/${await this.id(nameOrId)}`);
    this.resolver.forget(this.path);
  }

  /**
   * Read the workspace until its setup settles. Resolves with it when it is
   * `ready`; throws `WorkspaceFailedError` when it is `failed`, and a
   * `ManagoatError` with code `timeout` when `timeoutMs` passes first.
   *
   * It polls rather than following `workspace.status` on `events()`: that
   * event is never replayed, so a follower has to read the workspace anyway
   * to know where it started. A read that fails in a way worth retrying (a
   * 5xx, a deploy, the network) is retried until the deadline; any other
   * failure is thrown.
   */
  async waitForReady(nameOrId: string, opts: WaitForReadyOptions = {}): Promise<Workspace> {
    const id = await this.id(nameOrId);
    const timeoutMs = opts.timeoutMs ?? 30 * 60_000;
    const intervalMs = opts.intervalMs ?? 2000;
    const deadline = Date.now() + timeoutMs;
    let last: Workspace | null = null;

    while (true) {
      if (opts.signal?.aborted) throw new ManagoatError(`Stopped waiting for workspace ${id}`);
      try {
        const workspace = await this.http.data<Workspace>("GET", `${this.path}/${id}`, {
          signal: opts.signal,
        });
        if (workspace.status !== last?.status) opts.onStatus?.(workspace);
        last = workspace;
        if (workspace.status === "ready") return workspace;
        if (workspace.status === "failed") throw new WorkspaceFailedError(workspace);
      } catch (error) {
        if (opts.signal?.aborted) throw new ManagoatError(`Stopped waiting for workspace ${id}`, { cause: error });
        if (!(error instanceof ManagoatError) || error instanceof WorkspaceFailedError || !transient(error)) {
          throw error;
        }
      }
      if (Date.now() + intervalMs > deadline) {
        throw new ManagoatError(
          `Workspace ${id} is still ${last?.status ?? "unread"} after ${timeoutMs} ms`,
          { code: "timeout", body: last },
        );
      }
      await sleep(intervalMs, opts.signal);
    }
  }

  /**
   * The entries of one directory on the workspace's machine, directories
   * first then by name. `path` is absolute or relative to `/home/sprite`;
   * omit it for `/home/sprite` itself.
   *
   * The four disk reads (this, `file`, `gitStatus`, `diff`) read the
   * workspace's current machine as `Managoat#sandboxFiles` reads a sandbox:
   * confined to `/home/sprite` and the working directory of every live
   * conversation in the workspace (`path_outside_sandbox` otherwise),
   * redacted with the workspace's environment and vault and every live
   * conversation's credentials, and answered only by a `ready` machine. A
   * parked, provisioning or lost one is `409 sandbox_not_ready` with its
   * status, and a read never wakes one Managoat parked. A workspace with no
   * machine at all is a `NotFoundError`.
   */
  async files(nameOrId: string, path?: string): Promise<SandboxListing> {
    return this.http.data<SandboxListing>("GET", `${this.path}/${await this.id(nameOrId)}/files`, {
      query: { path },
    });
  }

  /** One file on the workspace's machine; `content` is text or base64 per `encoding`. See `files`. */
  async file(nameOrId: string, path: string, opts: { maxBytes?: number } = {}): Promise<SandboxFile> {
    return this.http.data<SandboxFile>("GET", `${this.path}/${await this.id(nameOrId)}/file`, {
      query: { path, max_bytes: opts.maxBytes },
    });
  }

  /**
   * `git status` of the repository containing `path` (default `/home/sprite`)
   * on the workspace's machine. Entry paths are relative to `repoRoot`. See
   * `Managoat#sandboxGitStatus` for what it shows that a diff cannot.
   */
  async gitStatus(
    nameOrId: string,
    opts: { path?: string; untracked?: "normal" | "all" | "no" } = {},
  ): Promise<SandboxStatus> {
    return this.http.data<SandboxStatus>("GET", `${this.path}/${await this.id(nameOrId)}/git-status`, {
      query: { path: opts.path, untracked: opts.untracked },
    });
  }

  /** `git diff` of the repository containing `path` (default `/home/sprite`) on the workspace's machine. */
  async diff(
    nameOrId: string,
    opts: { path?: string; staged?: boolean; ref?: string; maxBytes?: number } = {},
  ): Promise<SandboxDiff> {
    return this.http.data<SandboxDiff>("GET", `${this.path}/${await this.id(nameOrId)}/diff`, {
      query: { path: opts.path, staged: opts.staged, ref: opts.ref, max_bytes: opts.maxBytes },
    });
  }

  private async id(nameOrId: string): Promise<string> {
    return (await this.resolver.resolve(this.path, "workspace", nameOrId)).id;
  }
}

/** A read worth repeating: the server or the way to it is briefly unavailable. */
function transient(error: ManagoatError): boolean {
  return error.status === 0 || error.status >= 500 || error.status === 429;
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = setTimeout(done, ms);
    function done() {
      signal?.removeEventListener("abort", done);
      clearTimeout(timer);
      resolve();
    }
    signal?.addEventListener("abort", done, { once: true });
  });
}
