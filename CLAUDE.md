# CLAUDE.md — Contributor Guide

Read by Claude Code and other coding agents at session start, and by people.
It holds the rules that are easy to get wrong, the commands, and links to the
one place each longer procedure lives. Keep it short; the detail belongs in
the files it points at.

| For | Read |
|---|---|
| Workstation setup, toolchain pins | [SETUP.md](SETUP.md) |
| Contribution steps, licensing, checks, flakes, API changes | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Server implementation conventions | [contributing/server.md](contributing/server.md) |
| CI jobs, coverage, partitions, cutting a release | [scripts/ci/README.md](scripts/ci/README.md) |
| Writing and checking manual pages | [contributing/docs.md](contributing/docs.md) |
| The hex-pinned `managoat_*` libraries | [contributing/component-libraries.md](contributing/component-libraries.md) |
| Why things are the way they are | [decisions/index.md](decisions/index.md) |
| Configuration reference | [docs/configuration.md](docs/configuration.md), `.env.example` |

## Product and goal

What Managoat is, in one paragraph, is the top of [README.md](README.md).
Managoat is a self-hosted product. Since 2026-10-12 it is not sold as a
hosted service: there is no billing, no growth target and no product
analytics, and `managoat.com` is the maintainer's own instance. No org/team
(shared people) or billing features are planned.

## Commands

```bash
mise install                        # Erlang/OTP 28 + Elixir 1.19.2, from .tool-versions
mix deps.get && mix setup           # dev DB: create + migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test                            # the whole suite, from the umbrella root
mix precommit                       # server checks: static analysis, sobelow, release assemble
mix precommit --full                # server checks plus the whole suite
mix precommit --list                # its stages; `mix precommit credo test` runs a subset
gh pr merge <N> --squash --admin    # merge a PR once its CI is green
```

Choose local checks by the changed component in
[CONTRIBUTING.md](CONTRIBUTING.md#before-you-push). Go, SDK and tooling changes
use their own checks; mixed changes combine the relevant checks.

Run every mix command through the pinned toolchain (activate mise, or
`mise exec -- mix ...`). `mix precommit` refuses a different Elixir.

## Repo layout

```
apps/fountain/             the server (Apache-2.0): lib/fountain/ contexts, lib/fountain_web/ Phoenix
cli/                       the Go CLI module (Apache-2.0); test it from its own directory
sdk/                       the TypeScript client, against one OpenAPI contract (CONTRIBUTING.md)
site/                      the managoat.com pages and the manual: a static Mix build, its own image and CI (site/README.md)
docs/                      the public manual's source; site/ publishes it at managoat.com/docs, the server only redirects there
```

The one `managoat_*` library Managoat uses (broker) is a hex package
pinned in `apps/fountain/mix.exs`, not a directory here. The ACP
peer, the sandbox adapters, the runtimes and the OAuth grant state machine
were folded back on 2026-10-15 and live in `apps/fountain/lib/managoat/`,
keeping their `Managoat.*` names. Both are tabled in
[contributing/component-libraries.md](contributing/component-libraries.md).

## The four primitives

| Primitive | Purpose |
|---|---|
| **Environment** | Baseline set of encrypted env vars + runtime config (packages, repos, scripts) attached to an agent. A conversation may name a different one at launch (`environment_id`, scoped by `agent.allowed_environment_ids`) |
| **Vault** | Free-floating bag of env-var overrides. Vault values **win on key collision** when merged with an environment at sandbox spawn |
| **Agent** | A named, re-runnable agent config: model, runtime, skills, MCP servers, optional environment |
| **Conversation** | A single run of an agent, in a sandbox of its own ([ADR 0073](decisions/0073-one-sandbox-per-conversation.md)) unless launched into a workspace (`workspace_id`, [ADR 0097](decisions/0097-workspaces.md)). Has turns, log events, and a status lifecycle |

A **workspace** is not a fifth primitive: it is a machine the caller keeps, set
up from an environment and a vault, that conversations are launched into, each
in its own working directory ([docs/primitives.md](docs/primitives.md#what-managoat-does-not-have)).

## Rules

- Scope every user-facing query by `user_id`; never use `_unsafe_*` as the
  first fetch in a user-facing request.
- Audit mutations in the context, with caller attribution. Never log secret
  values or audit inside a transaction.
- Keep unbuilt behavior explicit in decisions and documentation.
- Check that an issue or PR reference supports its accompanying statement.
- Use the pinned toolchain and focused tests while iterating.

For server changes, read the relevant sections of
[Server conventions](contributing/server.md): tenant ownership, encryption,
audit, UI boundaries, web plumbing and test setup. Read a procedure
when the change touches it; the linked guides are reference material.

## How a change lands

[CONTRIBUTING.md](CONTRIBUTING.md#pull-requests) owns the landing procedure,
release notes and ADR trigger. Every change is a PR, merged with an admin
squash merge once its CI is green; there is no merge queue and no required
review. Never push directly to `main`: the Release bump workflow is the one
thing that does. CI administration lives in [scripts/ci/README.md](scripts/ci/README.md).

## Docs and decisions

- For documentation-only changes, use the focused checks in
  [contributing/docs.md](contributing/docs.md); contributor-only Markdown
  needs no server suite.
- `docs/` is published at managoat.com/docs only, by `site/` (ADR 0081), and
  describes `main`. A page not in `docs/nav.yml` fails the site's suite
  (`cd site && mix test`), as does a dead internal link or anchor. The structural rules and
  writing guidance are in [contributing/docs.md](contributing/docs.md).
- Architecturally significant choices are ADRs in `decisions/`, an OKF
  bundle: copy `decisions/0001-template.md`, then run
  `scripts/decisions-index.sh` and `okf validate decisions` in the same PR.
  `okf backlinks decisions <id>` lists what depends on one before amending it.
