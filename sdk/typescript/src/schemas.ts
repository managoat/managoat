/**
 * The API's own types, straight from its OpenAPI document.
 *
 * `src/generated/openapi.ts` is produced by `npm run generate` from the same
 * spec the server serves at `GET /api/openapi.json`, and CI regenerates it and
 * fails on a diff. So these are not a description of the API that someone has
 * to remember to update — they are the API, and a field added to a schema in
 * Elixir shows up here on the next build.
 *
 * The hand-written layer above this one exists for the things a spec cannot
 * express: what a *turn* is (many log events folded into one answer), that a
 * run can be awaited or streamed, and which of 85 paths are worth a verb.
 */
import type { components } from "./generated/openapi.ts";

type S = components["schemas"];

// ── the four primitives ──────────────────────────────────────────────────────

/** A named, re-runnable agent config — runtime, model, skills, environment. */
export type Agent = S["Agent"];
/** Everything that decides how a run behaves, before the prompt. */
export type AgentInput = S["AgentRequest"];
/** A partial agent definition, for `update`. */
export type AgentPatch = S["AgentUpdate"];

/** The sandbox shape an agent runs in: packages, repos, env vars, networking. */
export type Environment = S["Environment"];
export type EnvironmentInput = S["EnvironmentRequest"];
export type EnvironmentPatch = S["EnvironmentUpdate"];

/** A free-floating bag of env-var overrides, chosen per conversation. */
export type Vault = S["Vault"];
export type VaultInput = S["VaultRequest"];
export type VaultPatch = S["VaultUpdate"];

/** One run of an agent inside a sandbox. */
export type ConversationRecord = S["Conversation"];
/** The API launch body, with wire names and server-owned validation. */
export type ConversationInput = S["ConversationCreateRequest"];
/** A machine, with the conversations on it. */
export type SandboxRecord = S["SandboxDetail"];
/** One directory on a sandbox, directories first (ADR 0039). */
export type SandboxListing = S["SandboxListing"];
/** One entry of a `SandboxListing`. */
export type SandboxEntry = S["SandboxEntry"];
/** One file on a sandbox, redacted; `content` is text or base64 per `encoding`. */
export type SandboxFile = S["SandboxFile"];
/** `git diff` of a repository on a sandbox, redacted. */
export type SandboxDiff = S["SandboxDiff"];
/** `git status` of a repository on a sandbox, one entry per changed path. */
export type SandboxStatus = S["SandboxStatus"];
/** One changed path of a `SandboxStatus`. */
export type SandboxChange = S["SandboxChange"];
/**
 * A machine the caller keeps (ADR 0097): set up once from an environment and
 * a vault, then any agent launched into it, each conversation in a working
 * directory of its own.
 */
export type Workspace = S["Workspace"];
/** What `workspaces.create` sends. Its environment, vault and provider are fixed for its life. */
export type WorkspaceInput = S["WorkspaceCreateRequest"];
/** A `workspace.status` frame on the account event stream. Live only: it is never replayed. */
export type WorkspaceStatusEvent = S["StreamWorkspaceStatus"];
/** One prompt and everything the agent did in response. */
export type Turn = S["Turn"];
/** One row of a conversation's log feed. */
export type LogEvent = S["LogEvent"];
/** A server-parsed piece of an agent's output (`?blocks=true`). */
export type Block = S["Block"];

// ── secrets ──────────────────────────────────────────────────────────────────

/** A stored secret. Values are write-only — the API never returns them. */
export type Secret = S["Secret"];
export type VaultSecret = S["VaultSecret"];
export type VaultSecretMetadataPatch = S["VaultSecretMetadataRequest"];

// ── everything else the SDK surfaces ─────────────────────────────────────────

/** The form vocabulary: runtimes, models, providers a client can offer. */
export type Catalog = S["CatalogResponse"]["data"];
/** One hit from full-text search across the caller's conversations. */
export type SearchHit = S["SearchHit"];
/** A node in a conversation's spawn tree. */
export type ConversationTreeNode = S["ConversationTreeNode"];
export type Repository = S["Repository"];
export type ImageInput = S["ImageInput"];
export type AuthMe = S["AuthMeResponse"];

/** Every path and operation, for callers reaching past the wrapped verbs. */
export type { paths, components, operations } from "./generated/openapi.ts";

// ── connections (ADR 0085) ───────────────────────────────────────────────────

/** A user's OAuth grant to one remote MCP server. Never carries a token. */
export type McpConnection = S["Connection"];
/** What `connections.create` sends: the server URL and, when asked, a client. */
export type McpConnectionInput = S["ConnectionRequest"];
/** A connection with the URL to open in a browser signed in to Managoat. */
export type McpConnectionLogin = S["ConnectionLogin"];
