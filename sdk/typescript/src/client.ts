import type { ConversationInput } from "./schemas.ts";
import { HttpClient, type FetchLike, type RequestOptions } from "./http.ts";
import { resolveConfig, type ConfigOptions, type ResolvedConfig } from "./config.ts";
import { Resolver } from "./resolve.ts";
import { Run, type RunOptions } from "./run.ts";
import { Conversation } from "./conversation.ts";
import { Agents, Connections, Environments, Vaults, Workspaces } from "./resources.ts";
import { normalizeStreams, streamPath, type StreamRequest } from "./sse.ts";
import type {
  AuthMe,
  Catalog,
  ConversationRecord,
  LogEvent,
  SandboxDiff,
  SandboxFile,
  SandboxListing,
  SandboxStatus,
  SandboxRecord,
  SearchHit,
} from "./types.ts";

export interface ManagoatOptions extends ConfigOptions {
  /** Swap the fetch implementation — a test server, a proxy, an instrumented one. */
  fetch?: FetchLike;
  /** Timeout for ordinary API calls, in ms. Streams are never timed out. */
  timeoutMs?: number;
}

export interface RunConfig extends RunOptions {
  /** The agent to run, by name or id. */
  agent: string;
  /**
   * A vault of secrets, by name or id. Its values win over the environment's
   * on a key collision, and they are attached when the sandbox spawns — the
   * prompt never carries them.
   */
  vault?: string;
  /** An environment to provision from instead of the agent's own, by name or id. */
  environment?: string;
  /**
   * Run on a workspace's machine, by id or exact name (never a prefix), beside whatever else runs
   * there, instead of in a sandbox of the conversation's own (ADR 0097). Sent
   * as `workspace_id`. The workspace fixes the environment and vault, so
   * `environment` and `vault` may only name its own (`422
   * workspace_fixes_environment` otherwise). Conversations in one workspace
   * can read and change each other's files and tokens; leave it out for
   * isolation. See `managoat.workspaces`.
   */
  workspace?: string;
  /**
   * The directory inside the sandbox the agent runs in, fixed for the
   * conversation's life: `/home/sprite` or a directory under it (for a
   * gemini agent, also under `/tmp`), created if missing. Omit it for the
   * runtime's default. With `workspace`, it is how several agents share one
   * machine in different folders.
   */
  cwd?: string;
  /** Display title for the conversation. */
  title?: string;
  /** Images to attach to the first prompt, as the API's `ImageInput` shape. */
  images?: unknown[];
  /**
   * Your own name for this submission, carried to the turn the prompt opens
   * and onto that turn's `started` event (#1406). Read it back on the turn to
   * find which turn was yours, instead of guessing from turn order. Not an
   * idempotency key: sending the same value twice opens two turns.
   */
  clientRequestId?: string;
  /**
   * Bind the conversation to an external channel. A second run with the same
   * channel, agent and vault continues that conversation instead of opening a
   * new one — how a chat harness keeps one thread on one sandbox.
   */
  channelId?: string;
  /** With `channelId`: open a new conversation anyway. */
  fresh?: boolean;
  /**
   * Name the conversation's machine instead of taking a generated one: the
   * suffix of an account-scoped name, sent as `machine_name`. Needs a server
   * from after v0.27.0; an older one ignores it.
   */
  machineName?: string;
  /**
   * @deprecated Use `machineName`. Sent as `sprite_name`, which the server
   * accepts until the release that drops the Fountain-name aliases.
   */
  spriteName?: string;
}

/**
 * A Managoat client.
 *
 * ```ts
 * const fountain = new Managoat();
 * const run = await managoat.run("Upgrade us to Phoenix 1.8 and open a PR", {
 *   agent: "reposage",
 *   vault: "github-bot",
 * });
 * console.log(run.text, run.url);
 * ```
 *
 * Credentials resolve the way the `managoat` CLI resolves them, so a script
 * inherits whatever already works in your terminal. See `resolveConfig`.
 */
export class Managoat {
  /** The raw HTTP client. Every endpoint this SDK does not wrap is still here. */
  readonly api: HttpClient;
  readonly config: ResolvedConfig;

  /** Define, read, change and delete agents. */
  readonly agents: Agents;
  /** Environments and their secrets. */
  readonly environments: Environments;
  /** Vaults and their secrets. */
  readonly vaults: Vaults;
  /** OAuth grants to remote MCP servers (ADR 0085). */
  readonly connections: Connections;
  /** Machines you keep and run many conversations on (ADR 0097). */
  readonly workspaces: Workspaces;

  private readonly resolver: Resolver;

  constructor(options: ManagoatOptions = {}) {
    this.config = resolveConfig(options);
    this.api = new HttpClient(this.config, {
      fetch: options.fetch,
      timeoutMs: options.timeoutMs,
    });
    this.resolver = new Resolver(this.api);
    this.agents = new Agents(this.api, this.resolver);
    this.environments = new Environments(this.api, this.resolver);
    this.vaults = new Vaults(this.api, this.resolver);
    this.connections = new Connections(this.api);
    this.workspaces = new Workspaces(this.api, this.resolver);
  }

  /**
   * Run an agent on a prompt in a fresh sandbox.
   *
   * Returns immediately with a handle: `await` it for the finished answer,
   * `for await` it for events as they land, or read `.textStream`. The work
   * starts either way.
   */
  run(prompt: string, config: RunConfig): Run {
    const options: RunOptions = {
      timeoutMs: config.timeoutMs,
      signal: config.signal,
      collectEvents: config.collectEvents,
      recovery: config.recovery,
    };

    return new Run(
      this.api,
      {
        start: async () => {
          const [agent, vaultId, environmentId, workspaceId] = await Promise.all([
            this.resolver.resolve("/api/agents", "agent", config.agent),
            this.resolver.resolveId("/api/vaults", "vault", config.vault),
            this.resolver.resolveId("/api/environments", "environment", config.environment),
            config.workspace
              ? this.resolver.resolveExact("/api/workspaces", "workspace", config.workspace).then((w) => w.id)
              : undefined,
          ]);

          const body: Record<string, unknown> = { agent_id: agent.id };
          if (prompt) body.prompt = prompt;
          if (vaultId) body.vault_id = vaultId;
          if (environmentId) body.environment_id = environmentId;
          if (workspaceId) body.workspace_id = workspaceId;
          if (config.cwd) body.cwd = config.cwd;
          if (config.title) body.title = config.title;
          if (config.images?.length) body.images = config.images;
          // Presence, not truthiness: an explicitly empty id is a 422 the caller
          // has to see, not a prompt that quietly runs uncorrelated.
          if (config.clientRequestId !== undefined) {
            body.client_request_id = config.clientRequestId;
          }
          if (config.channelId) body.channel_id = config.channelId;
          if (config.fresh) body.fresh = true;
          if (config.machineName) body.machine_name = config.machineName;
          if (config.spriteName) body.sprite_name = config.spriteName;

          return this.startConversation(body);
        },
      },
      options,
    );
  }

  /**
   * Run an API-shaped launch request using IDs, without name resolution.
   * Every request field goes to the server; local execution settings stay in
   * options. For a promptless creation, use api.request instead.
   */
  runRequest(request: ConversationInput, options: RunOptions = {}): Run {
    if (typeof request.prompt !== "string" || !request.prompt.trim()) {
      throw new TypeError("runRequest requires a non-empty prompt; use api.request for promptless creation");
    }
    const body = { ...request };
    return new Run(this.api, { start: () => this.startConversation(body) }, options);
  }

  private async startConversation(body: Record<string, unknown>) {
    const response = await this.api.request<{
      data: ConversationRecord;
      meta?: { resumed?: boolean };
    }>("POST", "/api/conversations", { body });
    const conversation = response.data;
    if (response.meta?.resumed === true) {
      // Resume only binds the channel; it does not submit the launch prompt.
      // Capture history before sending, so fast turns cannot be skipped.
      const hasPrompt = typeof body.prompt === "string" && body.prompt.length > 0;
      const after = hasPrompt ? await this.resume(conversation.id).cursor() : 0;
      const turnNumber = await this.nextTurnNumber(conversation.id);
      // Every create field that belongs *with* the prompt has to be repeated
      // here: this second request is the one that actually opens the turn.
      const promptBody: Record<string, unknown> = { prompt: body.prompt };
      if (body.images !== undefined) promptBody.images = body.images;
      if (body.client_request_id !== undefined) {
        promptBody.client_request_id = body.client_request_id;
      }
      if (hasPrompt) {
        await this.api.request("POST", `/api/conversations/${conversation.id}/prompts`, {
          body: promptBody,
        });
      }
      return { conversation, turnNumber, after, clientRequestId: body.client_request_id as string | undefined };
    }
    return { conversation, turnNumber: 1, after: 0, clientRequestId: body.client_request_id as string | undefined };
  }

  /**
   * Pick a conversation back up. The sandbox is still there and so is the
   * agent's session — `send` costs one prompt, not a re-explanation.
   */
  resume(conversationId: string): Conversation {
    return new Conversation(this.api, conversationId);
  }

  /**
   * The account's conversations, newest first.
   *
   * Roots only by default: a conversation an agent spawned from inside a
   * sandbox is listed under its parent's tree, not again at the top level.
   * Pass `{ rootsOnly: false }` for the flat list, children included.
   *
   * `labels` keeps the conversations carrying every pair given — the wire is
   * a repeatable `label=key:value`, combined with AND.
   */
  async conversations(
    opts: { rootsOnly?: boolean; sandboxId?: string; labels?: Record<string, string> } = {},
  ): Promise<ConversationRecord[]> {
    return this.api.list<ConversationRecord>("/api/conversations", {
      query: {
        roots_only: opts.rootsOnly === false ? undefined : "true",
        sandbox_id: opts.sandboxId,
        label: opts.labels && Object.entries(opts.labels).map(([k, v]) => `${k}:${v}`),
      },
    });
  }

  /**
   * Who this key belongs to. The cheapest way to check a key works.
   *
   * `request`, not `data`: this is one of the few endpoints that answers with
   * the object itself rather than `{data: …}`, so unwrapping would hand back
   * `null` for a call that succeeded. `test/server.ts` lists the others.
   */
  async me(): Promise<AuthMe> {
    return this.api.request<AuthMe>("GET", "/api/auth/me");
  }

  /**
   * The form vocabulary: the runtimes, models and providers this deployment
   * offers. A client that builds an agent form reads it from here rather than
   * hard-coding a list that goes stale on the next Managoat release.
   */
  async catalog(): Promise<Catalog> {
    return this.api.data<Catalog>("GET", "/api/catalog");
  }

  /**
   * The account's sandboxes — the machine each conversation runs on — newest
   * first, each with its conversation.
   */
  async sandboxes(opts: { status?: string[] } = {}): Promise<SandboxRecord[]> {
    return this.api.list<SandboxRecord>("/api/sandboxes", {
      query: { status: opts.status?.join(",") },
    });
  }

  /** One sandbox, by id. */
  async sandbox(id: string): Promise<SandboxRecord> {
    return this.api.data<SandboxRecord>("GET", `/api/sandboxes/${id}`);
  }

  /**
   * The entries of one directory on a sandbox, directories first then by
   * name (ADR 0039). `path` is absolute or relative to the agent's working
   * directory; omit it for that directory itself. On a workspace's machine,
   * which several conversations share, a relative path resolves from
   * `/home/sprite` instead; `workspaces.files` reads it by workspace.
   *
   * The four disk reads — this, `sandboxFile`, `sandboxGitStatus` and
   * `sandboxDiff` — are the whole of what the API offers on a disk; there is
   * no exec, and to run a command you send a prompt. They need a `full`-scope key, answer only for
   * a `ready` sandbox (one Managoat parked is not resumed:
   * `sandbox_not_ready`; a `ready` one its provider put to sleep is woken,
   * and billed), are
   * confined to `/home/sprite` and the agent's working directory (on a
   * workspace's machine, every live conversation's) (`path_outside_sandbox`),
   * and come back redacted — the sandbox's
   * environment and vault values read `[REDACTED]`, as in the transcript.
   */
  async sandboxFiles(id: string, path?: string): Promise<SandboxListing> {
    return this.api.data<SandboxListing>("GET", `/api/sandboxes/${id}/files`, { query: { path } });
  }

  /**
   * One file on a sandbox. `content` is the text when `encoding` is `utf-8`
   * and base64 otherwise; `size` is the whole file and `truncated` says
   * whether `content` is short of it. That is true when the file is longer
   * than `maxBytes` (default 256 KiB, at most 4 MiB), and also when redaction
   * grows what was read past that cap.
   */
  async sandboxFile(id: string, path: string, opts: { maxBytes?: number } = {}): Promise<SandboxFile> {
    return this.api.data<SandboxFile>("GET", `/api/sandboxes/${id}/file`, {
      query: { path, max_bytes: opts.maxBytes },
    });
  }

  /**
   * `git status` of the repository containing `path` on a sandbox (default:
   * the agent's working directory), one entry per changed path.
   *
   * This is the read that shows a file the agent made and never staged:
   * `sandboxDiff` compares tracked content, so an untracked file is invisible
   * to it whatever options it is given. Entries cover the whole repository
   * whatever `path` names inside it, and each entry's `path` is relative to
   * `repoRoot` rather than to the sandbox home, so do not hand one straight
   * back to `sandboxFile` without joining it.
   *
   * `untracked` is `normal` (the default, an untracked directory collapses to
   * one entry), `all` (every file under it) or `no`.
   */
  async sandboxGitStatus(
    id: string,
    opts: { path?: string; untracked?: "normal" | "all" | "no" } = {},
  ): Promise<SandboxStatus> {
    return this.api.data<SandboxStatus>("GET", `/api/sandboxes/${id}/git-status`, {
      query: { path: opts.path, untracked: opts.untracked },
    });
  }

  /**
   * `git diff` of the repository containing `path` on a sandbox (default:
   * the agent's working directory). `staged` diffs the index; `ref` diffs
   * against a commit, branch or tag. With neither, the comparison is the
   * working tree against the index, so work the agent staged is absent from
   * it — pass `ref: "HEAD"` to see staged and unstaged together.
   */
  async sandboxDiff(
    id: string,
    opts: { path?: string; staged?: boolean; ref?: string; maxBytes?: number } = {},
  ): Promise<SandboxDiff> {
    return this.api.data<SandboxDiff>("GET", `/api/sandboxes/${id}/diff`, {
      query: { path: opts.path, staged: opts.staged, ref: opts.ref, max_bytes: opts.maxBytes },
    });
  }

  /** Full-text search across the caller's conversations. */
  async search(query: string, opts: { limit?: number } = {}): Promise<SearchHit[]> {
    return this.api.list<SearchHit>("/api/search", { query: { q: query, limit: opts.limit } });
  }

  /**
   * Every conversation the caller owns, on one connection — for a dashboard,
   * a conversation list with live status, or a process watching work it
   * spawned itself. Each event carries its `conversation_id`.
   */
  events(options: StreamRequest = {}): AsyncIterable<LogEvent> {
    return streamPath(this.api, "/api/events/stream", { blocks: true, ...normalizeStreams(options) });
  }

  /** Forget the memoized agent/vault/environment listings. */
  refresh(): void {
    this.resolver.clear();
  }

  /** Shorthand for `api.request`, for endpoints this SDK does not wrap. */
  request<T = unknown>(method: string, path: string, options?: RequestOptions): Promise<T> {
    return this.api.request<T>(method, path, options);
  }

  private async nextTurnNumber(conversationId: string): Promise<number> {
    const turns = await this.api.list<{ turn_number?: number }>(
      `/api/conversations/${conversationId}/turns`,
    );
    return turns.reduce((max, t) => Math.max(max, Number(t.turn_number) || 0), 0) + 1;
  }
}

/**
 * @deprecated The project was renamed Managoat (ADR 0082). Use
 * {@link Managoat}; `Fountain` is the same class, and a later major removes
 * the alias.
 */
export const Fountain = Managoat;
/** @deprecated Use {@link Managoat}. */
export type Fountain = Managoat;
/** @deprecated Use {@link ManagoatOptions}. */
export type FountainOptions = ManagoatOptions;
