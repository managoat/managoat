import { AuthError, ConnectionError, ManagoatError, errorForStatus } from "./errors.ts";
import type { ResolvedConfig } from "./config.ts";

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface RequestOptions {
  query?: Record<string, string | number | boolean | string[] | undefined | null>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  /** Per-request timeout. Defaults to the client's. `0` disables it. */
  timeoutMs?: number;
  accept?: string;
}

/**
 * The product token this client sends. Deliberately not the package name: a
 * scope reads as a second token in a User-Agent (`@managoat/…/0.1.1`), and
 * this string is already what Managoat's request logs are keyed on. The
 * version half is asserted against `package.json` by a test.
 */
export const USER_AGENT = "managoat-sdk-js/12.5.0";

/**
 * The thin layer everything else is built on: one bearer token, JSON in and
 * out, and errors that say which call failed. `Managoat#api` exposes it
 * directly so a caller is never blocked by a verb this SDK did not wrap.
 */
/** A page in a browser: `document` exists. Workers have none, and no page origin to preflight for. */
function isBrowser(): boolean {
  return typeof (globalThis as { document?: unknown }).document !== "undefined";
}

export class HttpClient {
  readonly config: ResolvedConfig;
  private readonly fetchImpl: FetchLike;
  private readonly defaultTimeoutMs: number;

  constructor(config: ResolvedConfig, opts: { fetch?: FetchLike; timeoutMs?: number } = {}) {
    this.config = config;
    this.fetchImpl = opts.fetch ?? ((input, init) => globalThis.fetch(input, init));
    this.defaultTimeoutMs = opts.timeoutMs ?? 30_000;
  }

  get baseUrl(): string {
    return this.config.baseUrl;
  }

  url(path: string, query?: RequestOptions["query"]): string {
    const url = new URL(path.startsWith("http") ? path : this.config.baseUrl + path);
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value === undefined || value === null || value === "") continue;
      // An array is a repeated key, not a comma-joined string. That is what
      // `style: form, explode: true` means in the OpenAPI document, and it is
      // how `?label=env:prod&label=drift:true` reaches the server; joining
      // them would send one filter Managoat cannot parse.
      if (Array.isArray(value)) {
        for (const item of value) url.searchParams.append(key, String(item));
        continue;
      }
      url.searchParams.set(key, String(value));
    }
    return url.toString();
  }

  headers(extra?: Record<string, string>): Record<string, string> {
    if (!this.config.apiKey) {
      throw new AuthError(
        "No Managoat API key. Pass `apiKey`, set MANAGOAT_API_KEY, or run `managoat auth login`.",
      );
    }
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.config.apiKey}`,
      Accept: "application/json",
      ...extra,
    };
    // A browser already has a user agent, and setting one is worse than
    // useless there: Chrome drops it as a forbidden header, Firefox sends it —
    // which makes every call a CORS preflight asking for `user-agent`, and a
    // server whose allow-list does not name it refuses the request outright
    // ("CORS Missing Allow Header"). Only a non-browser runtime gets the token.
    if (!isBrowser()) headers["User-Agent"] = USER_AGENT;
    // Attribute conversations started from inside a sandbox to their parent.
    // A server from before ADR 0082 reads only the X-Fountain spelling.
    if (this.config.parentConversationId) {
      headers["X-Managoat-Parent-Conversation-Id"] = this.config.parentConversationId;
      headers["X-Fountain-Parent-Conversation-Id"] = this.config.parentConversationId;
    }
    return headers;
  }

  /** Send a request and return the parsed body. Non-2xx throws. */
  async request<T = unknown>(method: string, path: string, opts: RequestOptions = {}): Promise<T> {
    const response = await this.raw(method, path, opts);
    const text = await response.text();
    const parsed = text ? safeJson(text) : null;
    if (!response.ok) {
      throw errorForStatus(
        response.status,
        parsed,
        method,
        this.url(path, opts.query),
        response.headers,
      );
    }
    return parsed as T;
  }

  /** Send a request and return the `Response` — for SSE and image bytes. */
  async raw(method: string, path: string, opts: RequestOptions = {}): Promise<Response> {
    const url = this.url(path, opts.query);
    const headers = this.headers(opts.headers);
    if (opts.accept) headers.Accept = opts.accept;

    let body: string | undefined;
    if (opts.body !== undefined) {
      body = JSON.stringify(opts.body);
      headers["Content-Type"] = "application/json";
    }

    const timeoutMs = opts.timeoutMs ?? this.defaultTimeoutMs;
    const signal = withTimeout(opts.signal, timeoutMs);

    try {
      return await this.fetchImpl(url, { method, headers, body, signal });
    } catch (cause) {
      if (opts.signal?.aborted) {
        throw new ManagoatError(`${method} ${url} was aborted`, { cause });
      }
      throw new ConnectionError(
        `${method} ${url} failed: ${describe(cause)}. ` +
          "If this is a browser, check the base URL and that API_CORS_ORIGINS on the " +
          "Managoat server includes this origin.",
        { cause },
      );
    }
  }

  /** `{data: T}` is the envelope every collection and show action uses. */
  async data<T>(method: string, path: string, opts: RequestOptions = {}): Promise<T> {
    const out = await this.request<{ data?: T }>(method, path, opts);
    return (out?.data ?? null) as T;
  }

  async list<T>(path: string, opts: RequestOptions = {}): Promise<T[]> {
    return (await this.data<T[]>("GET", path, opts)) ?? [];
  }
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function describe(cause: unknown): string {
  if (cause instanceof Error) return cause.message;
  return String(cause);
}

/**
 * Compose the caller's signal with a deadline. `AbortSignal.any` keeps the
 * caller's abort reason intact, which is what makes `run({ signal })` report
 * "aborted" rather than "timed out".
 */
function withTimeout(signal: AbortSignal | undefined, timeoutMs: number): AbortSignal | undefined {
  if (!timeoutMs || timeoutMs <= 0) return signal;
  const timeout = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}
