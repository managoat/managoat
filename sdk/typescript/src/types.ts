/**
 * The SDK's own vocabulary.
 *
 * Anything the API defines comes from `schemas.ts`, which is generated from
 * the OpenAPI document — so it cannot drift. What is left here is what a spec
 * cannot say: that many log events fold into one *turn*, that a run can be
 * awaited or streamed, and how a turn ended.
 */
export type {
  Agent,
  AgentInput,
  AgentPatch,
  AuthMe,
  Block,
  Catalog,
  ConversationRecord,
  ConversationTreeNode,
  Environment,
  EnvironmentInput,
  EnvironmentPatch,
  ImageInput,
  LogEvent,
  McpConnection,
  McpConnectionInput,
  McpConnectionLogin,
  Repository,
  SandboxChange,
  SandboxDiff,
  SandboxEntry,
  SandboxFile,
  SandboxListing,
  SandboxRecord,
  SandboxStatus,
  SearchHit,
  Secret,
  Turn,
  Vault,
  VaultInput,
  VaultPatch,
  VaultSecret,
  VaultSecretMetadataPatch,
  Workspace,
  WorkspaceField,
  WorkspaceInput,
  WorkspaceSetupEvent,
  WorkspaceSetupLog,
  WorkspaceSetupStep,
  WorkspaceSetupStepName,
  WorkspaceStatusEvent,
  ConversationsChangedEvent,
} from "./schemas.ts";

import type {
  Agent,
  Block,
  ConversationRecord,
  ConversationsChangedEvent,
  LogEvent,
  WorkspaceSetupEvent,
  WorkspaceStatusEvent,
} from "./schemas.ts";

/** A log event on the account stream, which says whose conversation it is. */
export type AccountLogEvent = LogEvent & { conversation_id: string };

/**
 * What `managoat.events()` yields. Switch on `kind`, the frame's SSE event
 * name: `output` and `stage` are log events; `workspace.status` (one of the
 * caller's workspaces changed status), `workspace.setup` (output from one of
 * their setups, as it runs) and `conversations` (the conversation list
 * changed) are notices, carry no `id`, and are not replayed after a
 * reconnect.
 */
export type AccountEvent =
  | AccountLogEvent
  | (WorkspaceStatusEvent & { kind: "workspace.status" })
  | (WorkspaceSetupEvent & { kind: "workspace.setup" })
  | (ConversationsChangedEvent & { kind: "conversations" });

/** The agent runtimes Managoat can start. */
export type Runtime = NonNullable<Agent["runtime"]>;

/** Sandbox backends. `null` on an agent means "the instance default". */
export type SandboxProvider = NonNullable<Agent["sandbox_provider"]>;

/** A conversation's lifecycle status. */
export type ConversationStatus = ConversationRecord["status"];

/**
 * A skill given to an agent — either written into the sandbox verbatim, or
 * installed from GitHub. Exactly one of `content` or `source` per entry; the
 * spec cannot express that, so this narrows what the generated type allows.
 */
export type SkillInput =
  | { name: string; content: string; source?: never; ref?: never }
  | { source: string; ref?: string; name?: string; content?: never };

/** The log-event streams a conversation carries. */
export type Stream = "stdout" | "stderr" | "acp" | "stage";

/**
 * One choice an agent offered when it asked permission. `optionId` is what an
 * answer sends back; `kind` is the vocabulary a UI can render without reading
 * the label (`allow_once`, `allow_always`, `reject_once`, `reject_always`, …).
 * Runtimes may add fields, so the rest is left open.
 */
export interface PermissionOption {
  optionId: string;
  kind?: string;
  name?: string;
  [key: string]: unknown;
}

/**
 * The agent is holding a tool call, waiting to be told whether to run it.
 *
 * Only agents with an `ask` entry in `permission_policy` produce these; the
 * default is `auto_allow` and never asks. Nothing else in the turn advances
 * until this is answered, and if nobody answers before the server's timeout it
 * is denied — so a caller that ignores these on an `ask` agent gets a turn that
 * does less than it was told to, not an error.
 */
export interface PermissionRequest {
  /** Pass this to `answer`. */
  requestId: string;
  /** What the agent wants to do, in the runtime's words. */
  summary: string | null;
  /** The tool it is asking about. Claude titles this with the command itself. */
  toolName: string | null;
  toolId: string | null;
  /** The choices the agent offered, in its order. Answer with one of these. */
  options: PermissionOption[];
}

/**
 * The agent is holding a form, waiting for a person to fill it: Claude's
 * `AskUserQuestion` (one to four questions, each a select with a free-text
 * "Other" field), an MCP server's form, or a prompt to retry a refused request
 * on another model.
 *
 * Only Claude agents produce these. Nothing else in the turn advances until
 * it is answered, and if nobody answers before the server's timeout it is
 * declined, which Claude reads as the person skipping the questions.
 */
export interface ElicitationRequest {
  /** Pass this to `answerElicitation`. */
  requestId: string;
  /** What the agent is asking, in its words. */
  message: string;
  /**
   * The form: a JSON Schema object whose `properties` are the fields. A select
   * offers its choices as `oneOf` (or `enum`) on a string, or `items.anyOf`
   * (or `items.enum`) on an array; each choice's `const` is the value to send.
   */
  schema: Record<string, unknown>;
  /** The tool call the form belongs to, when it belongs to one. */
  toolId: string | null;
}

/** A value in an accepted form: what the field's `type` says. */
export type ElicitationValue = string | number | boolean | string[];

/**
 * The answer to a form. `accept` sends `content`, keyed by the schema's
 * property names; `decline` says no (Claude reads it as "skipped"); `cancel`
 * dismisses the form (Claude aborts the tool call).
 */
export type ElicitationAnswer =
  | { action: "accept"; content?: Record<string, ElicitationValue> }
  | { action: "decline" }
  | { action: "cancel" };

/** How a turn ended. `timeout` means the SDK stopped waiting, not that the agent did. */
export type TurnState = "done" | "failed" | "interrupted" | "timeout";

/** What a run emits while it works. */
export type RunEvent =
  | { type: "conversation"; conversationId: string; conversation: ConversationRecord; url: string }
  | { type: "turn-start"; turnNumber: number; turnId: string | null }
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "tool"; name: string; block: Block }
  | { type: "permission"; request: PermissionRequest; block: Block }
  | { type: "elicitation"; request: ElicitationRequest; block: Block }
  | { type: "block"; block: Block; event: LogEvent }
  | { type: "event"; event: LogEvent }
  | { type: "turn-end"; state: TurnState; exitCode: number | null; reason: string | null };

/** The finished turn. */
export interface RunResult {
  /** The conversation the turn ran in. Keep it: the sandbox is still there. */
  conversationId: string;
  /** Where a human watches it. */
  url: string;
  /** Which turn this was — 1 for a fresh `run`, 2+ for a `send`. */
  turnNumber: number;
  /** Everything the agent said, tool noise removed. */
  text: string;
  /** Tool names the agent used, in the order it first used each. */
  toolsUsed: string[];
  /** How the turn ended. */
  state: TurnState;
  /** The runtime's exit code when it reported one. */
  exitCode: number | null;
  /** Why it stopped, when the runtime said. */
  reason: string | null;
  /** Whether the server says an unrun prompt can be submitted again. Never replayed automatically. */
  retryable?: boolean;
  /** The conversation's status when the turn ended. */
  status: string | null;
  /** Every log event consumed, when `collectEvents` was set. */
  events?: LogEvent[];
}

/** A named thing an agent can be given: an environment or a vault. */
export interface NamedResource {
  id: string;
  name: string;
  [key: string]: unknown;
}
