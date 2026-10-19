/**
 * Failures, keyed the way callers actually branch on them.
 *
 * The apps built on Managoat switch on the server's `error` string, not on the
 * status: `conversation_busy` is a 400 and `provisioning` is a 503, and what a UI wants to say about each has nothing
 * to do with those numbers. So `code` is the primary axis here, status the
 * secondary one, and the conditions worth retrying say so themselves.
 */
import type { Workspace } from "./schemas.ts";

/** The `error` strings the API sends. Open — a new one is a string, not a break. */
export type ManagoatErrorCode =
  | "conversation_busy"
  | "provisioning"
  | "sprite_probe_failed"
  | "sandbox_at_capacity"
  | "sandbox_not_found"
  | "sandbox_not_attachable"
  | "sandbox_identity_mismatch"
  | "sandbox_runtime_mismatch"
  | "fleet_full"
  | "rate_limited"
  | "environment_not_allowed"
  | "environment_not_found"
  | "vault_not_allowed"
  | "parent_conversation_not_found"
  | "workspace_fixes_environment"
  | "machine_name_with_workspace"
  | "invalid_sandbox_api_access"
  | "source_in_use_by_workspace"
  | "sandbox_not_ready"
  | "workspace_failed"
  | "not_found"
  | "unauthorized"
  | (string & {});

export interface ManagoatErrorInit {
  status?: number;
  code?: ManagoatErrorCode;
  body?: unknown;
  /** Seconds the server asked us to wait, from `Retry-After`. */
  retryAfter?: number | null;
  cause?: unknown;
}

export class ManagoatError extends Error {
  /** HTTP status, or 0 for a transport-level failure. */
  readonly status: number;
  /** The API's `error` field when it sent one. */
  readonly code: ManagoatErrorCode | undefined;
  /** The parsed response body, whatever shape it had. */
  readonly body: unknown;
  /** Seconds to wait before retrying, when the server said. */
  readonly retryAfter: number | null;

  constructor(message: string, init: ManagoatErrorInit = {}) {
    super(message, init.cause !== undefined ? { cause: init.cause } : undefined);
    this.name = new.target.name;
    this.status = init.status ?? 0;
    this.code = init.code;
    this.body = init.body;
    this.retryAfter = init.retryAfter ?? null;
  }

  /**
   * Whether trying the same call again could work. True for a busy
   * conversation, a sandbox still coming up, a rate limit and 5xx — false for
   * anything the caller has to change first.
   */
  get retryable(): boolean {
    if (RETRYABLE_CODES.has(this.code ?? "")) return true;
    return this.status === 429 || (this.status >= 500 && this.status < 600);
  }

  /** `errors: {field: [msg, …]}` as the server sends a 422; empty otherwise. */
  get fieldErrors(): Record<string, string[]> {
    const errors = (this.body as { errors?: unknown } | null)?.errors;
    if (!errors || typeof errors !== "object" || Array.isArray(errors)) return {};
    const out: Record<string, string[]> = {};
    for (const [field, value] of Object.entries(errors as Record<string, unknown>)) {
      if (Array.isArray(value)) out[field] = value.filter((v): v is string => typeof v === "string");
      else if (typeof value === "string") out[field] = [value];
    }
    return out;
  }
}

/**
 * @deprecated The project was renamed Managoat (ADR 0082). Use
 * {@link ManagoatError}; `FountainError` is the same class, and a later major
 * removes the alias.
 */
export const FountainError = ManagoatError;
/** @deprecated Use {@link ManagoatError}. */
export type FountainError = ManagoatError;
/** @deprecated Use {@link ManagoatErrorCode}. */
export type FountainErrorCode = ManagoatErrorCode;

const RETRYABLE_CODES = new Set([
  "conversation_busy",
  "provisioning",
  "sprite_probe_failed",
  // Another conversation's turn is using a one-at-a-time runtime's sandbox;
  // it clears when that turn ends.
  "sandbox_at_capacity",
  "rate_limited",
]);

/** No API key, or the key was rejected (401). */
export class AuthError extends ManagoatError {}

/** Wrong id, or it belongs to another account — Managoat does not distinguish (404). */
export class NotFoundError extends ManagoatError {}

/** The request was well-formed but rejected (422). Read `fieldErrors`. */
export class ValidationError extends ManagoatError {}

/** Too many requests (429). */
export class RateLimitError extends ManagoatError {}

/**
 * The agent is still working on the previous prompt (`conversation_busy`, a
 * 400). Wait for the turn in flight, then send again — `Conversation#send`
 * with `waitForIdle` does that for you.
 */
export class ConversationBusyError extends ManagoatError {}

/**
 * The sandbox is not up yet, Managoat could not reach the provider to check
 * (`provisioning` / `sprite_probe_failed`), or the deployment is at its fleet
 * ceiling (`fleet_full`) — all 503 with a `Retry-After`. Nothing is wrong and
 * nothing was changed; the same call will work shortly.
 */
export class NotReadyError extends ManagoatError {}


/** `run`/`send` gave up waiting. The turn is still running — resume it. */
export class TimeoutError extends ManagoatError {
  readonly conversationId: string;
  /** Whatever the agent had said by the deadline. */
  readonly partialText: string;
  constructor(message: string, conversationId: string, partialText: string) {
    super(message);
    this.conversationId = conversationId;
    this.partialText = partialText;
  }
}

/**
 * A workspace's setup failed (`status: "failed"`), seen by
 * `workspaces.waitForReady`. `workspace.error` says which step failed and
 * the end of what it printed, redacted. A prompt into a conversation in the
 * workspace retries the setup.
 */
export class WorkspaceFailedError extends ManagoatError {
  readonly workspace: Workspace;
  constructor(workspace: Workspace) {
    super(
      `Workspace ${workspace.name ?? workspace.id} failed to set up` +
        (workspace.error ? `: ${workspace.error}` : ""),
      { code: "workspace_failed", body: workspace },
    );
    this.workspace = workspace;
  }
}

/** A name that matched no agent/vault/environment, or matched more than one. */
export class ResolutionError extends ManagoatError {}

/**
 * The request never reached Managoat. In a browser this is nearly always CORS
 * or a wrong base URL, and the message says so, because "Failed to fetch" has
 * sent more than one person hunting through their own code.
 */
export class ConnectionError extends ManagoatError {}

const HINTS: Record<number, string> = {
  400: "bad request",
  401: "unauthorized — check the API key",
  403: "forbidden — the key may lack the scope for this call",
  404: "not found — wrong id, or it belongs to another account",
  409: "conflict",
  422: "rejected",
  429: "rate limited",
  503: "temporarily unavailable",
};

/** Pick the class for a failure. `code` decides; status is the fallback. */
export function errorForStatus(
  status: number,
  body: unknown,
  method: string,
  url: string,
  headers?: Headers,
): ManagoatError {
  const record = body && typeof body === "object" ? (body as Record<string, unknown>) : null;
  const code = typeof record?.error === "string" ? record.error : undefined;

  let detail = "";
  if (record) {
    const message = record.message ?? record.error ?? record.errors;
    detail = typeof message === "string" ? message : message === undefined ? "" : JSON.stringify(message);
  } else if (typeof body === "string" && body.trim()) {
    detail = body.trim().slice(0, 300);
  }

  const retryHeader = headers?.get("retry-after");
  const retryAfter = retryHeader && Number.isFinite(Number(retryHeader)) ? Number(retryHeader) : null;

  const message = [`HTTP ${status}`, HINTS[status], detail, `(${method} ${url})`]
    .filter(Boolean)
    .join(" ");
  const init: ManagoatErrorInit = { status, code, body, retryAfter };

  switch (code) {
    case "conversation_busy":
      return new ConversationBusyError(message, init);
    case "provisioning":
    case "sprite_probe_failed":
    case "sandbox_unavailable":
      return new NotReadyError(message, init);
    case "fleet_full":
      return new NotReadyError(message, init);
  }

  switch (status) {
    case 401:
      return new AuthError(message, init);
    case 404:
      return new NotFoundError(message, init);
    case 422:
      return new ValidationError(message, init);
    case 429:
      return new RateLimitError(message, init);
    default:
      return new ManagoatError(message, init);
  }
}
