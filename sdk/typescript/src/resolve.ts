import type { HttpClient } from "./http.ts";
import { ResolutionError } from "./errors.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Named {
  id: string;
  name?: string;
  [key: string]: unknown;
}

/**
 * Turns `{ agent: "reposage" }` into an id.
 *
 * Names, not ids, are the point: a script that reads `vault: "github-bot"` says
 * what it does, and a UUID in a README kills the demo. Resolution is exact
 * (case-insensitive) first, then a unique prefix, and a miss lists what the
 * account actually has — the error a caller can act on without opening the
 * console.
 */
export class Resolver {
  private readonly cache = new Map<string, Promise<Named[]>>();
  private readonly http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  /** Drop every memoized listing. */
  clear(): void {
    this.cache.clear();
  }

  /** Drop one memoized listing — after a create, rename or delete. */
  forget(path: string): void {
    this.cache.delete(path);
  }

  list(path: string): Promise<Named[]> {
    let pending = this.cache.get(path);
    if (!pending) {
      pending = this.http.list<Named>(path).catch((error) => {
        // A failed listing must not be remembered as an empty account.
        this.cache.delete(path);
        throw error;
      });
      this.cache.set(path, pending);
    }
    return pending;
  }

  async resolve(path: string, what: string, nameOrId: string): Promise<Named> {
    const wanted = (nameOrId ?? "").trim();
    if (!wanted) throw new ResolutionError(`${what} is required (a name or id)`);

    // An id needs no listing — and an account with hundreds of agents should
    // not pay for one on every call.
    if (UUID.test(wanted)) {
      const known = (await this.peek(path))?.find((item) => item.id === wanted);
      return known ?? { id: wanted };
    }

    const items = await this.list(path);
    const byId = items.find((item) => item.id === wanted);
    if (byId) return byId;

    const lower = wanted.toLowerCase();
    const exact = items.filter((item) => (item.name ?? "").toLowerCase() === lower);
    if (exact.length === 1) return exact[0] as Named;
    if (exact.length > 1) {
      throw new ResolutionError(
        `More than one ${what} is named ${JSON.stringify(wanted)}. Use the id: ` +
          exact.map((item) => item.id).join(", "),
      );
    }

    const prefix = items.filter((item) => (item.name ?? "").toLowerCase().startsWith(lower));
    if (prefix.length === 1) return prefix[0] as Named;
    if (prefix.length > 1) {
      throw new ResolutionError(
        `${JSON.stringify(wanted)} matches more than one ${what}: ` +
          prefix.map((item) => item.name ?? item.id).join(", "),
      );
    }

    throw new ResolutionError(
      `No ${what} named ${JSON.stringify(wanted)}. On this account: ${describe(items)}`,
    );
  }

  /**
   * `resolve` without the conveniences: an id, or a name matched exactly,
   * case and all. For a workspace, where a prefix that lands on the wrong one
   * puts a run inside someone else's trust boundary.
   */
  async resolveExact(path: string, what: string, nameOrId: string): Promise<Named> {
    const wanted = (nameOrId ?? "").trim();
    if (!wanted) throw new ResolutionError(`${what} is required (a name or id)`);
    if (UUID.test(wanted)) return { id: wanted };

    const items = await this.list(path);
    const exact = items.filter((item) => item.name === wanted);
    if (exact.length === 1) return exact[0] as Named;
    if (exact.length > 1) {
      throw new ResolutionError(
        `More than one ${what} is named ${JSON.stringify(wanted)}. Use the id: ` +
          exact.map((item) => item.id).join(", "),
      );
    }
    throw new ResolutionError(
      `No ${what} named exactly ${JSON.stringify(wanted)}. On this account: ${describe(items)}`,
    );
  }

  async resolveId(path: string, what: string, nameOrId?: string | null): Promise<string | undefined> {
    if (!nameOrId) return undefined;
    return (await this.resolve(path, what, nameOrId)).id;
  }

  /** The cached listing if we already have one; never fetches. */
  private async peek(path: string): Promise<Named[] | null> {
    const pending = this.cache.get(path);
    if (!pending) return null;
    return pending.catch(() => null);
  }
}

function describe(items: Named[]): string {
  const names = items
    .map((item) => item.name ?? item.id)
    .filter(Boolean)
    .sort();
  return names.length ? names.join(", ") : "(none)";
}
