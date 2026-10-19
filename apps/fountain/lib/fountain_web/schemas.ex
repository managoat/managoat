defmodule FountainWeb.Schemas do
  @moduledoc """
  OpenAPI schemas shared across controllers. One module per resource so
  controller `operation` decls can reference them by atom (e.g.
  `Schemas.Agent`).
  """

  import FountainWeb.SchemaWrappers,
    only: [
      list_response: 2,
      item_response: 2,
      update_of: 2,
      networking_config_description: 0
    ]

  alias OpenApiSpex.Schema

  defmodule Sandbox do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Sandbox",
      description:
        "One machine. Provisioned for a conversation; several conversations may run on " <>
          "it at once (ADR 0023).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        machine_name: %Schema{
          type: :string,
          description:
            "The machine's name at its provider, the same on every provider. " <>
              "Generated names read fountain-<account>-<suffix>."
        },
        sprite_name: %Schema{
          type: :string,
          deprecated: true,
          description:
            "The same value as machine_name, under its old name. Removed in the " <>
              "release that drops the Fountain-name aliases, planned for about 2026-11-15."
        },
        status: %Schema{
          type: :string,
          enum: ~w(pending starting ready suspended terminated failed)
        },
        transition: %Schema{
          type: :string,
          nullable: true,
          enum: Fountain.Conversations.Sandbox.transitions(),
          description:
            "An unfinished machine operation, or null. Wait for ready with a null transition " <>
              "before reading files; resuming includes the Sprites exec readiness probe."
        },
        agent_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The agent the machine was built for."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          deprecated: true,
          description:
            "Always ephemeral: every sandbox is one conversation's, destroyed when it ends. " <>
              "Persistent sandboxes were removed."
        },
        url: %Schema{
          type: :string,
          nullable: true,
          description:
            "The sandbox's own HTTP endpoint, where a service the agent starts " <>
              "is reachable. Null for providers that expose no such URL. The " <>
              "same value is available inside the sandbox as `SANDBOX_URL`."
        },
        provider: %Schema{
          type: :string,
          description:
            "The sandbox backend this row lives on: sprites or e2b. A sandbox " <>
              "created before the Daytona provider or the self-hosted runner was " <>
              "removed (2026-10) reads daytona or runner and is terminated."
        }
      },
      required: [:id, :machine_name, :sprite_name, :status]
    })
  end

  defmodule Workspace do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Workspace",
      description:
        "A machine the caller keeps (ADR 0097): set up once from an environment and a vault, " <>
          "then any agent launched into it with workspace_id, each conversation in a config " <>
          "home and working directory of its own. Its environment, vault and provider are " <>
          "fixed at create. An implicit workspace is the one a conversation launched without " <>
          "workspace_id gets for its own sandbox, and ends with it.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{
          type: :string,
          nullable: true,
          description: "The name it was created with; null for an implicit workspace."
        },
        implicit: %Schema{
          type: :boolean,
          description: "True for a conversation's own workspace, which ends with it."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox_provider: %Schema{type: :string, description: "sprites or e2b."},
        status: %Schema{
          type: :string,
          enum: Fountain.Workspaces.Workspace.statuses(),
          description:
            "The provision's outcome: provisioning while its machine is being set up (on " <>
              "create, on a retry, or on a rebuild after a loss), then ready or failed. A " <>
              "park does not move it; sandbox_status does. Each change is a " <>
              "workspace.status event on GET /api/events/stream."
        },
        error: %Schema{
          type: :string,
          nullable: true,
          description:
            "Why the provision failed, when status is failed: the failing step and the end " <>
              "of what it printed, redacted like the transcript. Null otherwise. A prompt " <>
              "into a conversation in a failed workspace retries the provision."
        },
        sandbox_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The machine the workspace has now, or null when it has none live (lost, or a " <>
              "failed provision). " <>
              "Not a handle to keep: a machine lost at its provider is rebuilt under a new id."
        },
        sandbox_status: %Schema{
          type: :string,
          nullable: true,
          description:
            "Its current machine's own status (pending, starting, ready or suspended): " <>
              "suspended while parked, which the next prompt " <>
              "wakes. Null when it has none live: lost at its provider, or a failed provision, " <>
              "and the next prompt builds the next."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :name,
        :implicit,
        :environment_id,
        :vault_id,
        :sandbox_provider,
        :status,
        :error,
        :sandbox_id,
        :sandbox_status,
        :inserted_at,
        :updated_at
      ]
    })
  end

  item_response(WorkspaceResponse, of: Workspace)

  list_response(WorkspaceListResponse, of: Workspace)

  defmodule WorkspaceCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WorkspaceCreateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "The environment its machine is set up from: packages, repositories and setup " <>
              "script, run once on create. One of the caller's (404 environment_not_found " <>
              "otherwise)."
        },
        vault_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional vault whose secrets override the environment's, as at a launch. One of " <>
              "the caller's (404 vault_not_found otherwise)."
        },
        sandbox_provider: %Schema{
          type: :string,
          nullable: true,
          description:
            "sprites or e2b; the instance default when omitted. A provider this instance has " <>
              "not enabled is refused with 422 sandbox_provider_disabled."
        }
      },
      required: [:name, :environment_id]
    })
  end

  defmodule StreamWorkspaceStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StreamWorkspaceStatus",
      description:
        "A `workspace.status` frame on the events SSE stream: one of the caller's " <>
          "workspaces changed status. Sent live only, with no event id, so it is not " <>
          "replayed after a reconnect; read GET /api/workspaces/{id} for the state.",
      type: :object,
      properties: %{
        workspace_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: Fountain.Workspaces.Workspace.statuses()},
        error: %Schema{type: :string, nullable: true}
      },
      required: [:workspace_id, :name, :status, :error]
    })
  end

  defmodule SandboxConversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxConversation",
      description: "A conversation on a sandbox, as the sandbox lists it.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ~w(pending running idle failed terminated)},
        title: %Schema{type: :string, nullable: true},
        runtime: %Schema{
          type: :string,
          description:
            "claude, codex, gemini or acp. A row written before the opencode runtime " <>
              "was removed (2026-10) still reads opencode; such an agent cannot start " <>
              "a conversation until its runtime is changed."
        },
        mid_turn: %Schema{
          type: :boolean,
          description: "True while this conversation is running a turn on the machine."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status, :mid_turn]
    })
  end

  defmodule SandboxDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxDetail",
      description: "A sandbox with the conversations on it.",
      type: :object,
      properties:
        Map.merge(Sandbox.schema().properties, %{
          conversations: %Schema{
            type: :array,
            items: SandboxConversation,
            description: "Every conversation ever opened on this machine, newest first."
          },
          inserted_at: %Schema{type: :string, format: :"date-time"},
          last_resumed_at: %Schema{type: :string, format: :"date-time", nullable: true}
        }),
      required: [:id, :machine_name, :sprite_name, :status, :conversations]
    })
  end

  defmodule SandboxEntry do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxEntry",
      description: "One entry of a directory on a sandbox (ADR 0039).",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        type: %Schema{type: :string, enum: Fountain.SandboxFiles.entry_types()},
        size: %Schema{
          type: :integer,
          nullable: true,
          description: "Bytes, for a regular file; null otherwise."
        }
      },
      required: [:name, :type]
    })
  end

  defmodule SandboxListing do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxListing",
      description: "A directory on a sandbox, directories first then by name.",
      type: :object,
      properties: %{
        path: %Schema{type: :string, description: "The directory listed, absolute."},
        entries: %Schema{type: :array, items: SandboxEntry},
        truncated: %Schema{
          type: :boolean,
          description: "True when the directory holds more entries than were returned."
        }
      },
      required: [:path, :entries, :truncated]
    })
  end

  defmodule SandboxFile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxFile",
      description:
        "One file on a sandbox, redacted: the sandbox's environment and vault values " <>
          "read `[REDACTED]`.",
      type: :object,
      properties: %{
        path: %Schema{type: :string, description: "The file read, absolute."},
        size: %Schema{type: :integer, description: "The whole file, in bytes."},
        truncated: %Schema{
          type: :boolean,
          description:
            "True when `content` is not the whole file: either the file is longer than " <>
              "`max_bytes`, or redaction grew what was read past it. False means `content` " <>
              "is everything."
        },
        encoding: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.encodings(),
          description:
            "`utf-8` when `content` is the text itself; `base64` when it is not valid UTF-8."
        },
        content: %Schema{type: :string}
      },
      required: [:path, :size, :truncated, :encoding, :content]
    })
  end

  defmodule SandboxDiff do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxDiff",
      description: "`git diff` of a repository on a sandbox, redacted like a file.",
      type: :object,
      properties: %{
        path: %Schema{
          type: :string,
          description: "The directory the diff was asked for, absolute."
        },
        repo_root: %Schema{type: :string, description: "The repository's top-level directory."},
        staged: %Schema{
          type: :boolean,
          description: "True when the index was diffed (`--cached`)."
        },
        ref: %Schema{
          type: :string,
          nullable: true,
          description: "The revision diffed against, or null when the caller named none."
        },
        diff: %Schema{type: :string, description: "Unified diff, no colour."},
        truncated: %Schema{
          type: :boolean,
          description:
            "True when `diff` is not the whole diff: either it is longer than `max_bytes`, " <>
              "or redaction grew what was read past it. False means `diff` is everything."
        }
      },
      required: [:path, :repo_root, :staged, :diff, :truncated]
    })
  end

  defmodule SandboxChange do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxChange",
      description:
        "One path `git status` reports, relative to `repo_root` (ADR 0039). " <>
          "An untracked file reads `untracked` on both sides, which is what git " <>
          "reports for it and the one state a diff cannot show.",
      type: :object,
      properties: %{
        path: %Schema{type: :string, description: "Relative to `repo_root`."},
        index: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.change_states(),
          description: "The staged side: what a commit would record."
        },
        worktree: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.change_states(),
          description: "The unstaged side: what the disk holds beyond the index."
        },
        renamed_from: %Schema{
          type: :string,
          nullable: true,
          description: "The old path, when that side is a rename or a copy; null otherwise."
        }
      },
      required: [:path, :index, :worktree]
    })
  end

  defmodule SandboxStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxStatus",
      description: "`git status` of a repository on a sandbox, one entry per changed path.",
      type: :object,
      properties: %{
        path: %Schema{
          type: :string,
          description: "The directory the status was asked for, absolute."
        },
        repo_root: %Schema{type: :string, description: "The repository's top-level directory."},
        branch: %Schema{
          type: :string,
          nullable: true,
          description: "The checked-out branch, or null on a detached HEAD."
        },
        untracked: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.untracked_modes(),
          description: "What was asked about untracked paths."
        },
        entries: %Schema{type: :array, items: SandboxChange},
        truncated: %Schema{
          type: :boolean,
          description: "True when the repository holds more changes than were returned."
        }
      },
      required: [:path, :repo_root, :untracked, :entries, :truncated]
    })
  end

  defmodule UsageAccounting do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UsageAccounting",
      description:
        "The adapter's accounting claim, not independently verified billing. " <>
          "Interpret source, version and scope together. Reported does not imply whole-conversation coverage.",
      type: :object,
      properties: %{
        version: %Schema{type: :integer, minimum: 1},
        source: %Schema{type: :string, minLength: 1, maxLength: 256},
        scope: %Schema{type: :string, minLength: 1, maxLength: 256},
        completeness: %Schema{type: :string, enum: ["reported", "partial"]}
      },
      required: [:version, :source, :scope, :completeness]
    })
  end

  defmodule TurnUsage do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TurnUsage",
      description:
        "The turn's token usage as the runtime reported it when the turn ended " <>
          "(the ACP `session/prompt` response's `usage`). The cache fields appear " <>
          "only when the runtime reports them. Accounting is absent for unqualified or historical reports. " <>
          "A metadata-only report has no measured token counts; missing counts are not zero.",
      type: :object,
      properties: %{
        accounting: UsageAccounting,
        input: %Schema{type: :integer, minimum: 0},
        output: %Schema{type: :integer, minimum: 0},
        cache_read: %Schema{type: :integer, minimum: 0, nullable: true},
        cache_write: %Schema{type: :integer, minimum: 0, nullable: true}
      },
      required: []
    })
  end

  defmodule UsageTotal do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UsageTotal",
      description: "Running sums of `input` and `output` over the turns that reported a usage.",
      type: :object,
      properties: %{
        input: %Schema{type: :integer, minimum: 0},
        output: %Schema{type: :integer, minimum: 0}
      },
      required: [:input, :output]
    })
  end

  defmodule PermissionPolicy do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PermissionPolicy",
      description:
        "The wire shape of a permission policy: a map of key to verdict. " <>
          "Every place a policy travels shares this shape and says there what a " <>
          "policy means at that door. Null everywhere a policy is absent.",
      type: :object,
      # Nullable HERE, not only on the five properties that reference this.
      # In OpenAPI 3.0 `nullable` relaxes the type of the schema it sits on and
      # nothing else, so a `nullable: true` wrapper whose shape comes from an
      # `allOf` branch still fails a standards validator on null: the branch is
      # what carries `type: object`, and it is the branch that refuses. The
      # five inline copies this replaced each wrote `type: :object` and
      # `nullable: true` on one node; hoisting the pair together is what keeps
      # that meaning. "a composed property that says nullable accepts null" in
      # schema_guardrail_test.exs is the guard.
      nullable: true,
      additionalProperties: %Schema{
        type: :string,
        enum: Managoat.ACP.Permissions.buildable_verdicts()
      },
      required: []
    })
  end

  defmodule SessionConfig do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SessionConfig",
      description:
        "ACP session config options an agent requests (ADR 0062): a map of the adapter's option " <>
          "id to a value, a string or a boolean. The ids and values are the adapter's own " <>
          "and are not checked against a list: claude-agent-acp offers `effort` and `fast`, " <>
          "codex-acp `reasoning_effort` and `fast-mode`, and which exist depends on the " <>
          "model. They are applied after the model and before each prompt. An id the " <>
          "adapter does not advertise is skipped, and a `config` stage event reports it " <>
          "(`done`, outcome `skipped`). " <>
          "A value it refuses fails the turn. `model` is refused here; use the model field. " <>
          "So are the permission mode ids, `mode` and `collaboration_mode`: the runtime's " <>
          "permission mode follows `permission_policy`. " <>
          "`session_config_options` on the conversation lists what the adapter offers.",
      type: :object,
      # Nullable on the schema itself for the reason `PermissionPolicy` gives.
      nullable: true,
      maxProperties: Fountain.Agents.SessionConfig.max_options(),
      # anyOf, not oneOf: a string that reads as a boolean ("true") would match
      # both branches under the caster, and oneOf refuses a double match.
      additionalProperties: %Schema{
        anyOf: [
          %Schema{
            type: :string,
            minLength: 1,
            maxLength: Fountain.Agents.SessionConfig.max_value_length()
          },
          %Schema{type: :boolean}
        ]
      },
      example: %{"effort" => "high", "fast" => true}
    })
  end

  defmodule SessionConfigOption do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SessionConfigOption",
      description:
        "One config option as the adapter advertised it (ACP `SessionConfigOption`), " <>
          "passed through unchanged. `category` is `thought_level` for reasoning effort " <>
          "and `model_config` for fast mode on the pinned adapters. `options` lists a " <>
          "select's values, possibly in groups. `currentValue` is the value in force.",
      type: :object,
      additionalProperties: true,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        category: %Schema{type: :string, nullable: true},
        type: %Schema{type: :string, description: "`select` or `boolean`."},
        currentValue: %Schema{anyOf: [%Schema{type: :string}, %Schema{type: :boolean}]},
        options: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        }
      },
      required: [:id]
    })
  end

  defmodule Conversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Conversation",
      description: "One chat with one agent inside one sandbox.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        title: %Schema{
          type: :string,
          nullable: true,
          description:
            "Optional display title, set explicitly or supplied by the harness over ACP. " <>
              "Harness titles may be revised or cleared; null when no title is set."
        },
        sandbox_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox: %Schema{
          anyOf: [%Schema{allOf: [Sandbox]}, %Schema{nullable: true, enum: [nil]}],
          nullable: true
        },
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        agent_version_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The agent config version this conversation launched under (ADR 0029): " <>
              "provenance only, the live agent still drives the sandbox. Null for a " <>
              "conversation that predates versioning. Resolve it at " <>
              "GET /api/agents/{agent_id}/versions/{agent_version}."
        },
        agent_version: %Schema{
          type: :integer,
          nullable: true,
          readOnly: true,
          description:
            "The version number behind agent_version_id, resolved on the list and get " <>
              "endpoints; null elsewhere and wherever agent_version_id is null."
        },
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox_api_access: %Schema{
          type: :string,
          enum: ~w(owner none),
          description:
            "Immutable sandbox callback credential policy. none never issues a callback token."
        },
        permission_policy: %Schema{
          allOf: [PermissionPolicy],
          nullable: true,
          description:
            "The per-launch permission override this conversation was started with, or " <>
              "null if it had none. The policy actually in force is this merged with the " <>
              "agent's, taking the stricter of the two per tool."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Per-launch environment override; null means the agent's environment. A " <>
              "conversation in a workspace carries the workspace's."
        },
        workspace_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The workspace (GET /api/workspaces/{id}) whose machine this conversation runs " <>
              "on: the one it was launched into, or, for a conversation with a sandbox of its " <>
              "own, that sandbox's implicit workspace (listed with ?implicit=true). Null for " <>
              "a conversation whose machine has ended with it."
        },
        session_config: %Schema{
          allOf: [SessionConfig],
          description:
            "The ACP session config options every turn of this conversation requests " <>
              "(ADR 0062): its agent's session_config, copied at launch and fixed for the " <>
              "conversation's life. {} requests none."
        },
        session_config_options: %Schema{
          type: :array,
          nullable: true,
          items: SessionConfigOption,
          description:
            "The config options the adapter advertised before the latest prompt, after " <>
              "the model and the requested options were applied: what the current model " <>
              "offers and what is in force. Read it to choose the agent's session_config. " <>
              "The permission mode options (`mode`, " <>
              "`collaboration_mode`) are left out, since session_config refuses them. " <>
              "Null until a turn reports them."
        },
        model: %Schema{
          type: :string,
          nullable: true,
          description:
            "This conversation's model override (ADR 0061), set at launch and fixed; " <>
              "null means it runs the agent's model. Each turn's model_selection records " <>
              "the model that turn actually asked for."
        },
        cwd: %Schema{
          type: :string,
          description:
            "The working directory the conversation's agent runs in, inside its sandbox: " <>
              "the cwd it was launched with, or its runtime's default (/home/sprite for " <>
              "claude, codex and acp, /tmp/gemini-workspace for gemini). Fixed for the " <>
              "conversation's life."
        },
        runtime: %Schema{
          type: :string,
          description:
            "claude, codex, gemini or acp. A row written before the opencode runtime " <>
              "was removed (2026-10) still reads opencode; such an agent cannot start " <>
              "a conversation until its runtime is changed."
        },
        status: %Schema{
          type: :string,
          enum: ~w(pending running idle failed terminated)
        },
        runtime_session_id: %Schema{type: :string, nullable: true},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        parent_conversation_id: %Schema{type: :string, format: :uuid, nullable: true},
        depth: %Schema{
          type: :integer,
          minimum: 0,
          readOnly: true,
          description:
            "How many conversations started this one: 0 for a start from outside any " <>
              "sandbox, and the starting conversation's depth plus one for a start " <>
              "from inside one. A start deeper than `CONVERSATION_MAX_DEPTH` is " <>
              "refused with 422 `conversation_depth_exceeded`."
        },
        channel_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "The external channel key this conversation is bound to, if it was created with one."
        },
        labels: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description:
            "Free-form key/value strings on the conversation. A program stamps its own " <>
              "run with them (`env=prod`, `drift=true`) and `GET /api/conversations?label=env:prod` " <>
              "filters on them. At most 32 entries; a key is at most 64 bytes and a value " <>
              "at most 256 bytes. Always an object, empty when nothing set one."
        },
        turn_count: %Schema{type: :integer},
        first_prompt: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description:
            "The first turn's prompt — what to title an untitled conversation " <>
              "with. Null until the first turn exists."
        },
        last_active_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "Most recent runtime output, falling back to creation time. Stage " <>
              "events (reconnects, sandbox lifecycle) do not count."
        },
        last_read_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Set by `POST /api/conversations/:id/read`. Null if never read."
        },
        unread: %Schema{
          type: :boolean,
          description: "last_active_at is later than last_read_at (true if never read)."
        },
        usage_total: UsageTotal,
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :runtime, :status]
    })
  end

  defmodule ConversationTreeNode do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationTreeNode",
      description: "One conversation in a spawn tree, flat with a parent pointer.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        status: %Schema{type: :string, enum: ~w(pending running idle failed terminated)},
        parent_id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:id]
    })
  end

  list_response(ConversationTreeResponse, of: ConversationTreeNode)

  defmodule ConversationResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationResponse",
      type: :object,
      properties: %{
        data: Conversation,
        meta: %Schema{
          type: :object,
          description: "Present when creating or resuming a conversation.",
          properties: %{
            resumed: %Schema{
              type: :boolean,
              description: "Whether the channel resumed an existing conversation."
            }
          },
          required: [:resumed]
        }
      },
      required: [:data]
    })
  end

  list_response(ConversationListResponse, of: Conversation)

  defmodule ImageInput do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImageInput",
      description: "A base64-encoded image to attach to a prompt.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :string,
          description: "Base64-encoded image bytes."
        },
        media_type: %Schema{
          type: :string,
          enum: ~w(image/png image/jpeg image/gif image/webp),
          description: "MIME type of the image."
        }
      },
      required: [:data, :media_type]
    })
  end

  defmodule ClientRequestId do
    @moduledoc false
    # One definition for the request side (#1406), so every door that takes a
    # prompt declares the same bound and says the same thing about it.

    @shared "Managoat stores it on the turn the prompt opens and sends it on that turn's " <>
              "`started` stage event, beside the `turn_id`, so a client can bind its work " <>
              "item to the exact turn without inferring it from turn order. Use the event " <>
              "to find a candidate turn and the turn itself to confirm it: the event's " <>
              "copy has been through event redaction, and the turn's is what you sent. " <>
              "It is a correlation and not an idempotency key: a second prompt with the " <>
              "same value opens a second turn that carries it too. Make it unique within " <>
              "the conversation."

    def request(lead \\ "Your own name for this prompt. ") do
      %Schema{
        type: :string,
        # Null is "none", as it is for `images` beside it: a client that
        # serialises an unset optional as null must not get a 422 for a
        # field it did not use.
        nullable: true,
        minLength: 1,
        maxLength: Fountain.Conversations.Turn.client_request_id_max(),
        # PostgreSQL cannot hold U+0000 in a text column: the insert raises
        # 22021, and nothing on the way to the turn rescues it. An otherwise
        # ordinary prompt would end its conversation server over the label it
        # carried, on a wake after the caller was already told `queued`. Every
        # other character is the caller's business, so this refuses exactly
        # one. `Turn.changeset/2` and `PromptDelivery.travelling/1` hold the
        # same line for a caller that is not a door.
        pattern: Fountain.Conversations.Turn.client_request_id_pattern(),
        description: lead <> @shared
      }
    end
  end

  defmodule ConversationCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationCreateRequest",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string, format: :uuid},
        vault_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional vault whose secrets override the environment's baseline at sprite spawn. " <>
              "Must satisfy the agent's allowed_vault_ids when that allowlist is set."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional environment to provision from instead of the agent's own; the " <>
              "conversation stays pinned to it across wakes. Must be owned by the caller " <>
              "(404 otherwise) and satisfy the agent's allowed_environment_ids when that " <>
              "allowlist is set (422 environment_not_allowed). Part of the channel_id " <>
              "resume key."
        },
        sandbox_api_access: %Schema{
          type: :string,
          enum: ~w(owner none),
          description:
            "none omits the sandbox Managoat credential on provision and every wake. Requires a fresh ephemeral sandbox; unavailable on attach or policy-changing channel resume."
        },
        cwd: %Schema{
          type: :string,
          nullable: true,
          maxLength: 1024,
          description:
            "The working directory the agent runs in, inside the sandbox: an absolute path " <>
              "under /home/sprite (or under /tmp for a gemini agent), outside " <>
              "/home/sprite/.managoat. Created if missing, and fixed for the conversation's " <>
              "life. Omitted or null runs the runtime's default (/home/sprite for claude, " <>
              "codex and acp, /tmp/gemini-workspace for gemini). Anything else is refused " <>
              "with 422 validation_failed and errors.cwd. On a channel_id resume it must " <>
              "name the directory the resumed conversation runs in, or be omitted."
        },
        permission_policy: %Schema{
          allOf: [PermissionPolicy],
          nullable: true,
          description:
            "Per-launch permission override (#939). Keys are matched against the tool " <>
              "card's title first and then ACP's kind (execute, edit, read, fetch, …); " <>
              "\"default\" covers the rest. Prefer a kind: claude titles a tool call with " <>
              "the command it is about to run, so a title matches one invocation only. " <>
              "Merged with the agent's own policy, taking the stricter of the two. It may " <>
              "only narrow: a policy that would loosen any tool is refused with 422 " <>
              "permission_policy_widens rather than silently clamped."
        },
        session_config: %Schema{
          type: :object,
          nullable: true,
          deprecated: true,
          additionalProperties: true,
          description:
            "No longer supported: a conversation requests its agent's session_config, " <>
              "copied at launch (ADR 0062). Null or {} is accepted for older clients; " <>
              "any other value is refused with 422 session_config_agent_only."
        },
        model: %Schema{
          type: :string,
          nullable: true,
          description:
            "Optional model to run instead of the agent's (ADR 0061), in canonical " <>
              "provider/model_id form, for this conversation only. Checked as the agent's " <>
              "own model is: a provider the runtime does not drive, or any model on the acp " <>
              "runtime, is 422 model_invalid. The model id itself is not checked against a " <>
              "catalog. Fixed for the conversation's life. Not part of the channel_id resume " <>
              "key: a request that resumes a conversation running a different model is 409 " <>
              "conversation_model_differs, before any prompt is sent; set fresh: true for a " <>
              "new conversation on it."
        },
        prompt: %Schema{
          type: :string,
          description:
            "Optional first turn prompt. A launch may open with no prompt at all, but a " <>
              "prompt that is present must carry words: blank and whitespace-only text is " <>
              "refused with 422 invalid_prompt, before the launch reserves a sandbox."
        },
        client_request_id:
          ClientRequestId.request(
            "Your own name for the first prompt. Ignored when the request carries no " <>
              "`prompt`. An immediate `channel_id` resume does not deliver the prompt; " <>
              "send the value with it on the prompts route."
          ),
        title: %Schema{
          type: :string,
          nullable: true,
          maxLength: 120,
          description: "Optional display title."
        },
        images: %Schema{
          type: :array,
          items: ImageInput,
          description:
            "Optional images to attach to the initial prompt. They require that prompt: " <>
              "images with no opening text are refused with 422 invalid_prompt, and an " <>
              "image whose media_type is unsupported or whose decoded bytes are empty or " <>
              "over the 10MB ceiling is refused with 422 invalid_images. Both refusals " <>
              "happen before a sandbox is reserved.",
          nullable: true
        },
        machine_name: %Schema{
          type: :string,
          description:
            "Name the conversation's machine instead of taking a generated name. " <>
              "The value is the suffix of an account-scoped name: the server keeps the " <>
              "fountain-<account>- prefix every generated name carries, so a name you " <>
              "choose lands in your own namespace rather than another account's. " <>
              "1 to 40 characters of letters, digits, - and _, starting with a letter " <>
              "or digit; a name that already carries this account's prefix is taken as " <>
              "it stands, so a name from an earlier launch resolves to the same machine. " <>
              "422 invalid_sprite_name otherwise (the code keeps its old name until the " <>
              "aliases go). Refused with sandbox_api_access none, which requires a machine " <>
              "no other conversation can reach."
        },
        sprite_name: %Schema{
          type: :string,
          deprecated: true,
          description:
            "The old name of machine_name, still accepted. Sending both with different " <>
              "values is refused with 422 machine_name_conflict. Removed in the release " <>
              "that drops the Fountain-name aliases, planned for about 2026-11-15."
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          nullable: true,
          deprecated: true,
          description:
            "Accepted as ephemeral or null for older clients: every conversation gets a " <>
              "sandbox of its own. persistent is refused with 422 persistent_sandbox_removed."
        },
        sandbox_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          deprecated: true,
          description:
            "No longer supported: a non-null value is refused with 422 " <>
              "sandbox_attach_unsupported. To run several conversations on one machine, " <>
              "launch each with the same workspace_id."
        },
        workspace_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Run the conversation on one of the caller's workspaces (POST /api/workspaces), " <>
              "in its own config home and working directory, beside any other conversations " <>
              "there. The agent supplies the runtime, model, skills, MCP servers and " <>
              "permission policy; the workspace supplies the machine, the environment and " <>
              "the vault, and its sandbox provider wins over the agent's. An environment_id " <>
              "or vault_id other than the workspace's is refused with 422 " <>
              "workspace_fixes_environment, and the agent's environment and vault " <>
              "allowlists apply to the workspace's (422 environment_not_allowed, " <>
              "vault_not_allowed). A workspace that is not the caller's is 404. Refused with " <>
              "sandbox_api_access none (422 invalid_sandbox_api_access) and with " <>
              "machine_name (422 machine_name_with_workspace), and refused to a sandbox's own " <>
              "key (403 insufficient_scope, required_scope full). A launch into a workspace " <>
              "still provisioning is accepted; its first prompt waits for it, and a prompt " <>
              "into a workspace whose provision failed retries it. Conversations in one " <>
              "workspace share one trust boundary: each can read the others' files and " <>
              "credentials. With channel_id, only a conversation in this workspace is resumed."
        },
        channel_id: %Schema{
          type: :string,
          maxLength: 255,
          nullable: true,
          description:
            "Opaque key for the external channel this conversation is bound to (for example a " <>
              "chat thread id). When set, the latest live conversation for the same agent, vault " <>
              "and channel is resumed (200) instead of a new one being opened (201)."
        },
        fresh: %Schema{
          type: :boolean,
          nullable: true,
          description:
            "With channel_id: skip the resume and open a new conversation (201), which then " <>
              "becomes the channel's binding. Sent by a chat harness relaying its owner's " <>
              "rotate command. Ignored without channel_id."
        },
        labels: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: %Schema{type: :string},
          description:
            "Key/value strings to stamp on the conversation. At most 32 entries; a key is " <>
              "at most 64 bytes and a value at most 256 bytes, and a 422 names the offending " <>
              "key under `errors.labels`. With channel_id, a resume merges these into the " <>
              "conversation it hands back rather than dropping them."
        }
      },
      required: [:agent_id]
    })
  end

  defmodule ConversationLabelsRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationLabelsRequest",
      description:
        "Labels to merge into a conversation. A key not named is left alone; a key whose " <>
          "value is null is removed.",
      type: :object,
      properties: %{
        labels: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string, nullable: true},
          description:
            "The pairs to merge. null removes a key. At most 32 entries survive the merge; " <>
              "a key is at most 64 bytes and a value at most 256 bytes. A 422 names the " <>
              "offending key under `errors.labels`."
        }
      },
      required: [:labels]
    })
  end

  defmodule ConversationWakeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationWakeResponse",
      type: :object,
      properties: %{
        status: %Schema{
          type: :string,
          enum: ["awake", "waking"],
          description:
            "`awake` when the conversation's server was already running and nothing was " <>
              "done; `waking` when this request started one. Its reattach or provision " <>
              "stages follow on the event stream."
        }
      },
      required: [:status]
    })
  end

  defmodule PromptRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptRequest",
      type: :object,
      properties: %{
        prompt: %Schema{type: :string},
        images: %Schema{
          type: :array,
          items: ImageInput,
          description: "Optional images to attach to this prompt.",
          nullable: true
        },
        client_request_id: ClientRequestId.request(),
        session_config: %Schema{
          type: :object,
          nullable: true,
          deprecated: true,
          additionalProperties: true,
          description:
            "No longer supported: every turn requests its conversation's agent's " <>
              "session_config, copied at launch (ADR 0062). Null or {} is accepted for " <>
              "older clients; any other value is refused with 422 session_config_agent_only."
        }
      },
      required: [:prompt]
    })
  end

  defmodule PromptResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, example: "queued"},
        client_request_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "The `client_request_id` the request carried, or null when it carried none. " <>
              "The response cannot name the turn: a conversation that has to be woken is " <>
              "answered before its turn exists. Find the turn by this value instead."
        }
      },
      # `client_request_id` is always rendered and deliberately not required: a
      # client generated from this document also reads servers from before it.
      required: [:status]
    })
  end

  defmodule PermissionAnswerRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PermissionAnswerRequest",
      description:
        "The answer to a request the agent is blocked on: `option_id` for a " <>
          "`permission_request`, `action` (and `content`) for an `elicitation_request`.",
      type: :object,
      properties: %{
        option_id: %Schema{
          type: :string,
          description:
            "permission_request only: one of the `optionId` values from the request's own " <>
              "`options` list, as carried on the `permission_request` block. An id the agent " <>
              "did not offer is refused (422 unknown_option) rather than forwarded."
        },
        action: %Schema{
          type: :string,
          enum: Managoat.ACP.Elicitation.actions(),
          description:
            "elicitation_request only: `accept` sends `content`; `decline` says no, which " <>
              "Claude's AskUserQuestion reads as the person skipping the questions; `cancel` " <>
              "dismisses the form, which aborts the AskUserQuestion tool call."
        },
        content: %Schema{
          type: :object,
          nullable: true,
          description:
            "elicitation_request with action `accept` only: the form's values, keyed by the " <>
              "property names in the block's `schema`. Each value is a string, a number, a " <>
              "boolean or a list of strings, as the property's type says; a select's value " <>
              "must be one of the choices the schema offers. Omit a property to leave it " <>
              "unanswered.",
          additionalProperties: true
        }
      }
    })
  end

  defmodule PermissionAnswerResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PermissionAnswerResponse",
      type: :object,
      properties: %{ok: %Schema{type: :boolean, example: true}},
      required: [:ok]
    })
  end

  defmodule Turn do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Turn",
      description: "One prompt → exit_code cycle within a conversation.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        turn_number: %Schema{type: :integer},
        prompt: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ~w(pending running completed failed interrupted)
        },
        # No `default:` here on purpose: one would make the generated TS
        # field non-optional (see sdk/typescript notes).
        client_request_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "The `client_request_id` of the prompt that opened this turn (#1406), or " <>
              "null: the caller sent none, or the turn is `autonomous`. Not unique. " <>
              "This is the value the caller sent, byte for byte, and it is the one to " <>
              "compare against: the copy on the turn's `started` stage event has been " <>
              "through event redaction, which rewrites any registered environment " <>
              "value it contains."
        },
        origin: %Schema{
          type: :string,
          enum: ~w(user autonomous),
          description:
            "Who opened the turn: `user` for a prompt somebody sent, `autonomous` " <>
              "for a turn the server opened for a background cycle the agent ran " <>
              "after its prompt was answered (#817)."
        },
        exit_code: %Schema{type: :integer, nullable: true},
        started_at: %Schema{type: :string, format: :"date-time", nullable: true},
        ended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        image_count: %Schema{
          type: :integer,
          description: "Number of images attached to this turn."
        },
        config_selection: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: true,
          description:
            "The ACP session config options of this turn (ADR 0062). `requested` is what " <>
              "the turn asked for: its agent's session_config as the conversation launched " <>
              "with it. `applied` maps each id the adapter took to the value it confirmed. " <>
              "`skipped` lists ids the adapter did not advertise. On a refusal, `status` is " <>
              "`failed` with `error`. Turns from before 2026-10-15 may also carry " <>
              "`restored`. Null on a turn that requested none."
        },
        model_selection: %Schema{
          type: :object,
          nullable: true,
          description: "ACP model selection evidence; null for turns without a selection report.",
          properties: %{
            requested_model: %Schema{type: :string, nullable: true},
            effective_model: %Schema{type: :string, nullable: true},
            status: %Schema{type: :string, enum: ~w(selected failed)},
            source: %Schema{type: :string, enum: ~w(runtime selection_ack), nullable: true},
            error: %Schema{type: :string}
          }
        },
        usage: %Schema{
          anyOf: [%Schema{allOf: [TurnUsage]}, %Schema{nullable: true, enum: [nil]}],
          nullable: true,
          description:
            "The end-of-turn token figure; null while the turn runs, when the runtime " <>
              "reported none, or on turns that predate the field."
        },
        inference: %Schema{
          type: :object,
          nullable: true,
          readOnly: true,
          description:
            "Which inference source served this turn, recorded once when the turn " <>
              "started and never rewritten: replacing the credential, relinking " <>
              "the subscription or restarting the conversation changes later turns only. " <>
              "Null on a turn that started before the source was recorded, and on a turn " <>
              "that ran on the deployment's credential before that was removed.",
          properties: %{
            scope: %Schema{
              type: :string,
              enum: ~w(credential tenant_secret grant none missing),
              description:
                "Where the credential came from: the account's inference credentials " <>
                  "(`credential`), an environment or vault value (`tenant_secret`), the " <>
                  "account's ChatGPT subscription (`grant`), or nowhere because the " <>
                  "provider needs none (`none`) or none was found (`missing`)."
            }
          },
          required: [:scope]
        }
      },
      required: [:id, :turn_number, :prompt, :status]
    })
  end

  list_response(TurnListResponse, of: Turn)

  defmodule Agent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Agent",
      description: "An AI agent definition: runtime, model, skills, MCP, env.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        system: %Schema{type: :string, description: "System prompt."},
        model: %Schema{
          type: :string,
          description:
            "Canonical provider/model_id (e.g. anthropic/claude-sonnet-5). The " <>
              "provider must match the runtime — anthropic for claude, openai for " <>
              "codex, google for gemini. Other " <>
              "providers are rejected: Managoat has no credentials to export for " <>
              "them. The model id is not checked against a list, so a newly " <>
              "released model works without a Managoat release. Null on the acp " <>
              "runtime, which resolves no inference credential and reads no model.",
          nullable: true,
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{
          type: :string,
          description:
            "claude, codex, gemini or acp. A row written before the opencode runtime " <>
              "was removed (2026-10) still reads opencode; such an agent cannot start " <>
              "a conversation until its runtime is changed."
        },
        runtime_command: %Schema{
          type: :string,
          nullable: true,
          description:
            "The command the acp runtime launches inside the sandbox, as a shell line " <>
              "resolved there (for example `chant acp`). Required when runtime is " <>
              "acp, and rejected on every other runtime, which resolves its own " <>
              "executable. A free string by design: it runs under the same isolation " <>
              "as an environment's setup script."
        },
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          deprecated: true,
          description:
            "Always ephemeral: every conversation gets a sandbox of its own. Persistent " <>
              "sandboxes were removed; on a request, persistent is refused with 422."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        session_config: %Schema{
          allOf: [SessionConfig],
          description:
            "ACP session config options every conversation of this agent requests " <>
              ~s|(ADR 0062), such as {"effort": "high"}. A conversation copies them when | <>
              "it is created, so an edit reaches conversations created after it, not " <>
              "running ones. Every turn of the conversation requests them; neither a " <>
              "conversation nor a prompt sets options of its own. Null or {} requests none."
        },
        permission_policy: %Schema{
          allOf: [PermissionPolicy],
          nullable: true,
          description:
            "Per-tool permission policy: a map of key to verdict, plus an optional " <>
              "\"default\" key. A key is matched against the tool card's title first and " <>
              "then ACP's kind (execute, edit, read, fetch, \u2026); prefer a kind, because " <>
              "claude titles a tool call with the command it is about to run. Unset keys " <>
              "fall back to the default, and an unset default is auto_allow \u2014 today's " <>
              "behaviour. \"ask\" holds the tool until a human answers it on the " <>
              "conversation stream, and denies if nobody does before the timeout."
        },
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — fetched from GitHub onto the sprite, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description:
                  "GitHub `owner/repo` for github entries, or `owner/repo/dir` to " <>
                    "search one directory of it.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(a full commit sha, not an abbreviated one). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist. Vault values override the agent's " <>
              "environment on key collision, so this scopes who can override reviewed config."
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        conversation_count: %Schema{
          type: :integer,
          description: "Conversations started from this agent."
        },
        avatar_media_type: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(image/png image/jpeg image/gif image/webp),
          description:
            "Set when the agent has an avatar; fetch the bytes at " <>
              "`GET /api/agents/:id/avatar`. Null means no avatar."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      # `model` stays required: the response always carries the key, and the
      # acp runtime's value for it is null rather than absent.
      required: [:id, :name, :model, :runtime]
    })
  end

  item_response(AgentResponse, of: Agent)

  list_response(AgentListResponse, of: Agent)

  defmodule AgentVersion do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentVersion",
      description:
        "One immutable snapshot of an agent's config (ADR 0029), written on create and on " <>
          "every update that changes a config field. `config` holds the full values, keyed " <>
          "by the agent fields `Agent.changeset/2` casts (everything but ownership and the " <>
          "avatar). Versions are read-only; to go back to one, update the agent with its " <>
          "`config`.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid},
        version: %Schema{type: :integer, description: "1-based, monotonic per agent."},
        config: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :agent_id, :version, :config, :inserted_at]
    })
  end

  item_response(AgentVersionResponse, of: AgentVersion)

  list_response(AgentVersionListResponse, of: AgentVersion)

  defmodule AgentRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        system: %Schema{type: :string},
        model: %Schema{
          type: :string,
          # Nullable so an agent converted to the acp runtime can clear the
          # model it no longer uses. CastAndValidate runs before the
          # changeset, so a non-nullable string here would reject the null
          # with a 400 and leave the stale value on the row forever.
          nullable: true,
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.packaged_runtimes()},
        runtime_command: %Schema{
          type: :string,
          nullable: true,
          description:
            "The command the acp runtime launches inside the sandbox, as a shell line " <>
              "resolved there (for example `chant acp`). Required when runtime is " <>
              "acp, and rejected on every other runtime, which resolves its own " <>
              "executable. A free string by design: it runs under the same isolation " <>
              "as an environment's setup script."
        },
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          deprecated: true,
          description:
            "Always ephemeral: every conversation gets a sandbox of its own. Persistent " <>
              "sandboxes were removed; on a request, persistent is refused with 422."
        },
        permission_policy: %Schema{
          allOf: [PermissionPolicy],
          nullable: true,
          description:
            "Per-tool permission policy: a map of key to verdict, plus an optional " <>
              "\"default\" key. A key is matched against the tool card's title first and " <>
              "then ACP's kind (execute, edit, read, fetch, \u2026); prefer a kind, because " <>
              "claude titles a tool call with the command it is about to run. Unset keys " <>
              "fall back to the default, and an unset default is auto_allow. \"ask\" holds " <>
              "the tool until a human answers it on the conversation stream, and denies if " <>
              "nobody does before the timeout. A conversation may narrow this at launch, " <>
              "never widen it."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        session_config: %Schema{
          allOf: [SessionConfig],
          description:
            "ACP session config options every conversation of this agent requests " <>
              ~s|(ADR 0062), such as {"effort": "high"}. A conversation copies them when | <>
              "it is created, so an edit reaches conversations created after it, not " <>
              "running ones. Every turn of the conversation requests them; neither a " <>
              "conversation nor a prompt sets options of its own. Null or {} requests none."
        },
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — fetched from GitHub onto the sprite, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description:
                  "GitHub `owner/repo` for github entries, or `owner/repo/dir` to " <>
                    "search one directory of it.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(a full commit sha, not an abbreviated one). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist."
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        }
      },
      # `model` is required for every runtime but acp, which needs none. A
      # conditional requirement is not expressible here, so the changeset is
      # where it is enforced and a missing model is a 422 rather than a 400.
      required: [:name, :runtime]
    })
  end

  update_of(AgentUpdate, AgentRequest)

  defmodule Repository do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Repository",
      type: :object,
      properties: %{
        url: %Schema{type: :string, format: :uri, pattern: "^https://"},
        mount_path: %Schema{type: :string, pattern: "^/"},
        # Both are read by `Provisioning.clone_https/4` and neither was
        # declared, so a private repository could not be expressed by a client
        # generated from this spec — and an unauthenticated clone of one fails
        # inside the sandbox rather than at the API.
        secret_key: %Schema{
          type: :string,
          description:
            "Name of a secret — on the environment or on a vault attached at launch — " <>
              "holding a token to clone with. The clone uses it as HTTPS " <>
              "`x-access-token` auth. Required for a private repository; omit it for a " <>
              "public one."
        },
        ref: %Schema{
          type: :string,
          description:
            "Optional branch or tag to clone (`git clone -b`). Without it the default " <>
              "branch is cloned."
        }
      },
      required: [:url, :mount_path]
    })
  end

  defmodule Environment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Environment",
      description: "A reusable sandbox environment: packages, env vars, repos, networking.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        setup_timeout_seconds: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 900,
          description:
            "Setup exec timeout in seconds; defaults to 120. The overall provisioning deadline still applies."
        },
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description: networking_config_description(),
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true},
        secret_count: %Schema{type: :integer, description: "Secrets stored on this environment."},
        agent_count: %Schema{
          type: :integer,
          description: "Agents referencing this environment — 0 means safe to delete."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  item_response(EnvironmentResponse, of: Environment)

  list_response(EnvironmentListResponse, of: Environment)
  item_response(SandboxResponse, of: SandboxDetail)
  list_response(SandboxListResponse, of: SandboxDetail)
  item_response(SandboxListingResponse, of: SandboxListing)
  item_response(SandboxFileResponse, of: SandboxFile)
  item_response(SandboxDiffResponse, of: SandboxDiff)
  item_response(SandboxStatusResponse, of: SandboxStatus)

  defmodule EnvironmentRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        setup_timeout_seconds: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 900,
          description:
            "Setup exec timeout in seconds; defaults to 120. The overall provisioning deadline still applies."
        },
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description: networking_config_description(),
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name]
    })
  end

  update_of(EnvironmentUpdate, EnvironmentRequest)

  defmodule Secret do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Secret",
      description: "A named secret. Values are write-only — the API never returns them.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string},
        environment_id: %Schema{type: :string, format: :uuid},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :environment_id]
    })
  end

  item_response(SecretResponse, of: Secret)

  list_response(SecretListResponse, of: Secret)

  defmodule SecretRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :string, description: "Secret value (write-only)."}
      },
      required: [:key, :value]
    })
  end

  defmodule Vault do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Vault",
      description:
        "A free-floating bag of env-var overrides selected at conversation creation. " <>
          "Vault values override an environment's baseline secrets when the same key is set on both.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true},
        secret_count: %Schema{type: :integer, description: "Secrets stored in this vault."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  item_response(VaultResponse, of: Vault)

  list_response(VaultListResponse, of: Vault)

  defmodule VaultRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name]
    })
  end

  update_of(VaultUpdate, VaultRequest)

  defmodule VaultSecret do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecret",
      description:
        "A named secret in a vault. Values are write-only — the API never returns them.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string},
        vault_id: %Schema{type: :string, format: :uuid},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :vault_id]
    })
  end

  item_response(VaultSecretResponse, of: VaultSecret)

  list_response(VaultSecretListResponse, of: VaultSecret)

  defmodule VaultSecretRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :string, description: "Secret value (write-only)."},
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "When the value stops working, as recorded by the owner. " <>
              "Advisory: nothing is enforced and nothing is sent."
        }
      },
      required: [:key, :value]
    })
  end

  defmodule VaultSecretMetadataRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretMetadataRequest",
      type: :object,
      additionalProperties: false,
      properties: %{
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Advisory expiry. Null clears it; omission keeps the current value."
        }
      }
    })
  end

  defmodule Block do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Block",
      description:
        "One structured piece of a log event's output — the same parse the web UI " <>
          "renders (`Fountain.Conversations.Blocks`). `kind` decides the other fields: " <>
          "`text`/`thinking` carry `body`; `plan` carries the full ordered checklist in `body` " <>
          "(entries with `content`, `status`, and optional `priority`, `id`, `activeForm`); " <>
          "`tool_use` carries `id`, `name`, `summary`, " <>
          "`body` (the input); `tool_result` carries `tool_id`, `body`, `error` and pairs " <>
          "with the `tool_use` of the same id; `init` carries `summary`, `body`; `result` " <>
          "carries `body`, `raw`; `error` carries `body`; `raw` carries `body`, `summary`; " <>
          "`permission_request` carries `request_id`, `name`, `summary` and `options` — the " <>
          "agent is blocked on it, and a client answers with " <>
          "POST /api/conversations/{id}/requests/{request_id}. Render only the options in " <>
          "`options`; never synthesise one the agent did not offer. `elicitation_request` " <>
          "carries `request_id`, `body` (the agent's message), `schema` (the form, a JSON " <>
          "Schema object of primitive-typed properties) and `tool_id` (the tool call it belongs " <>
          "to, when it belongs to one) — the agent is blocked on it too, and a client answers " <>
          "with an `action` on the same route. `prompt` carries `body` — " <>
          "the prompt that opened the turn, which is the one kind not parsed out of a " <>
          "runtime's output. It appears only on a turn's `turn`/`started` stage event, and " <>
          "only when the events feed was asked for it with `blocks=true&prompts=true`.",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          enum: Fountain.Conversations.Blocks.kinds()
        },
        body: %Schema{
          oneOf: [
            %Schema{type: :string, nullable: true},
            %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  content: %Schema{type: :string},
                  status: %Schema{type: :string, enum: ~w(pending in_progress completed)},
                  priority: %Schema{type: :string},
                  id: %Schema{type: :string},
                  activeForm: %Schema{type: :string}
                },
                required: [:content, :status],
                additionalProperties: true
              }
            }
          ]
        },
        summary: %Schema{type: :string, nullable: true},
        id: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string, nullable: true},
        tool_id: %Schema{type: :string, nullable: true},
        error: %Schema{type: :boolean, nullable: true},
        raw: %Schema{type: :string, nullable: true},
        request_id: %Schema{
          type: :string,
          nullable: true,
          description: "permission_request and elicitation_request only: the id to answer with."
        },
        schema: %Schema{
          type: :object,
          nullable: true,
          description:
            "elicitation_request only: the form, as the agent sent it (ACP's " <>
              "`requestedSchema`). `properties` maps each field name to a schema with a " <>
              "`type` (string, number, integer, boolean or array), an optional `title` and " <>
              "`description`, and for a select its choices: `oneOf` (or `enum`) on a string, " <>
              "`items.anyOf` (or `items.enum`) on an array, each option's `const` being the " <>
              "value to send. Claude's AskUserQuestion sends one `question_<n>` select and " <>
              "one free-text `question_<n>_custom` field per question.",
          additionalProperties: true
        },
        options: %Schema{
          type: :array,
          nullable: true,
          description:
            "permission_request only: the options the agent offered, in its order. " <>
              "Each carries at least `optionId` and `kind` (allow_once, allow_always, " <>
              "reject_once, reject_always, ...).",
          items: %Schema{type: :object, additionalProperties: true}
        }
      },
      required: [:kind],
      additionalProperties: true
    })
  end

  defmodule LogEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LogEvent",
      description:
        "One line of a conversation's log feed: runtime output or a lifecycle " <>
          "stage transition. Same fields the SSE stream sends, plus `id`.",
      type: :object,
      properties: %{
        id: %Schema{
          type: :integer,
          description: "Monotonic id. Pagination cursor here, `Last-Event-ID` on the SSE route."
        },
        kind: %Schema{type: :string, enum: ~w(output stage)},
        stream: %Schema{
          type: :string,
          description: "`stdout` / `stderr` for output events; empty for stage events."
        },
        data: %Schema{
          type: :string,
          description: "Output text, or JSON-encoded metadata for stage events."
        },
        stage: %Schema{
          type: :string,
          nullable: true,
          description: "Lifecycle stage name. null on an event that has no stage."
        },
        state: %Schema{
          type: :string,
          enum: ~w(started done failed interrupted),
          nullable: true,
          description: "Lifecycle state of the stage. null on an event that has no state."
        },
        duration_ms: %Schema{type: :integer, nullable: true},
        turn_id: %Schema{type: :string, format: :uuid, nullable: true},
        ts: %Schema{type: :string, format: :"date-time"},
        blocks: %Schema{
          type: :array,
          items: Block,
          description:
            "Only with `?blocks=true`: `data` parsed server-side into the blocks a " <>
              "transcript renders. Empty for non-output events."
        }
      },
      required: [:id, :kind, :ts]
    })
  end

  defmodule StreamLogEvent do
    @moduledoc false
    require OpenApiSpex

    # Reuses LogEvent's property definitions (minus `id`, which the SSE frame
    # carries in its `id:` line rather than the JSON body) so the two schemas
    # cannot drift on the fields they share. `required` follows the same rule:
    # whatever LogEvent requires other than `id`.
    OpenApiSpex.schema(%{
      title: "StreamLogEvent",
      description:
        "One frame of the conversation or events SSE log stream (#2297). Same " <>
          "fields as `LogEvent` minus `id` — the frame's id travels in the SSE `id:` " <>
          "line, never the JSON body — plus `conversation_id`, which the " <>
          "REST log feed never sends because its URL or list item already names the " <>
          "conversation.\n\n" <>
          "Not every stream sends every optional field here; see each property's own " <>
          "description for which of `GET /api/conversations/:id/stream` and " <>
          "`GET /api/events/stream` include it. The events stream also sends " <>
          "`StreamSignal` frames on the same connection.",
      type: :object,
      properties:
        LogEvent.schema().properties
        |> Map.delete(:id)
        |> Map.merge(%{
          duration_ms: %Schema{
            type: :integer,
            nullable: true,
            description:
              "Sent on `GET /api/events/stream`. Not sent on " <>
                "`GET /api/conversations/:id/stream`."
          },
          conversation_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "Which conversation this event belongs to. Sent on `GET /api/events/stream`; " <>
                "not sent on `GET /api/conversations/:id/stream`, " <>
                "whose URL already names the conversation."
          }
        }),
      required: LogEvent.schema().required -- [:id]
    })
  end

  defmodule StreamSignal do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StreamSignal",
      description:
        "A change-signal frame on the events SSE stream (#2297) — not a log " <>
          "event, and no `conversation_id` or anything else `StreamLogEvent` " <>
          "declares. The event name says what changed: `conversations` " <>
          "(the caller's conversation list changed — created, " <>
          "titled, read, deleted, finished). The client re-lists rather than " <>
          "reading anything from the body.",
      type: :object,
      properties: %{
        reason: %Schema{type: :string, enum: ~w(changed)}
      },
      required: [:reason]
    })
  end

  defmodule LogEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LogEventListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: LogEvent},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            has_more: %Schema{
              type: :boolean,
              description:
                "More matching events exist past this page: newer ones for `asc`, older " <>
                  "ones for `desc`."
            },
            next_cursor: %Schema{
              type: :integer,
              nullable: true,
              description:
                "The page's last event id: pass as `after` (`asc`) or `before` (`desc`) " <>
                  "to fetch the next page. null when the page is empty."
            }
          },
          required: [:limit, :has_more]
        },
        # Beside `meta` rather than in it: `meta` is the cursor envelope the
        # audit list shares, and the Swift SDK published the two as one
        # `PageMeta` type (#2300), so a field here would retype that.
        page: %Schema{
          type: :object,
          description: "The window this page covers (#2531).",
          properties: %{
            order: %Schema{
              type: :string,
              enum: ["asc", "desc"],
              description: "The order of `data`, as requested."
            },
            oldest_cursor: %Schema{
              type: :integer,
              nullable: true,
              description: "The smallest event id on the page. null when the page is empty."
            },
            newest_cursor: %Schema{
              type: :integer,
              nullable: true,
              description:
                "The largest event id on the page; on the first `order=desc` page, the " <>
                  "`Last-Event-ID` an SSE follow resumes from. null when the page is empty."
            },
            turn_split: %Schema{
              type: :boolean,
              description:
                "`whole_turns=true` reached its ceiling inside a turn: the page's oldest " <>
                  "turn continues on the next page. Always false otherwise."
            }
          },
          required: [:order, :oldest_cursor, :newest_cursor, :turn_split]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AdminUser do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUser",
      description: "An account as the operator surface sees it. Metadata only.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string},
        role: %Schema{type: :string, enum: ~w(admin user)},
        email_verified: %Schema{type: :boolean},
        email_verified_at: %Schema{type: :string, format: :"date-time", nullable: true},
        active_sandboxes: %Schema{type: :integer},
        last_activity_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :email, :role]
    })
  end

  item_response(AdminUserResponse, of: AdminUser)

  defmodule AdminCreateUserRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminCreateUserRequest",
      type: :object,
      properties: %{
        email: %Schema{
          type: :string,
          description: "The new account's address. Verified at creation; no mail is sent."
        },
        key_name: %Schema{
          type: :string,
          nullable: true,
          description: "Name of the API key minted with the account. Default `platform`."
        }
      },
      required: [:email],
      example: %{"email" => "helpdesk@apps.example.com"}
    })
  end

  defmodule AdminCreatedUserResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminCreatedUserResponse",
      type: :object,
      properties: %{
        data: AdminUser,
        api_key: %Schema{
          type: :string,
          description: "The new account's full-scope API key. Shown once; only its hash is kept."
        }
      },
      required: [:data, :api_key]
    })
  end

  defmodule AdminUserListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUserListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: AdminUser},
        meta: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer},
            per_page: %Schema{type: :integer},
            total: %Schema{type: :integer}
          },
          required: [:page, :per_page, :total]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AdminRoleRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminRoleRequest",
      type: :object,
      properties: %{role: %Schema{type: :string, enum: ~w(admin user)}},
      required: [:role]
    })
  end

  defmodule AdminSandbox do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSandbox",
      description: "A live sandbox, cross-tenant. Metadata only — never contents.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        machine_name: %Schema{type: :string, description: "The machine's name at its provider."},
        sprite_name: %Schema{
          type: :string,
          deprecated: true,
          description:
            "The same value as machine_name, under its old name. Removed in the " <>
              "release that drops the Fountain-name aliases, planned for about 2026-11-15."
        },
        provider: %Schema{type: :string, description: "Sandbox backend that owns this row"},
        status: %Schema{type: :string},
        user_id: %Schema{type: :string, format: :uuid, nullable: true},
        user_email: %Schema{type: :string, nullable: true},
        conversation_count: %Schema{type: :integer},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status]
    })
  end

  list_response(AdminSandboxListResponse, of: AdminSandbox)

  defmodule AdminReapResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminReapResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sandbox_id: %Schema{type: :string, format: :uuid},
            outcome: %Schema{type: :string, enum: ~w(terminated released already_terminal)}
          },
          required: [:outcome]
        }
      },
      required: [:data]
    })
  end

  # Fully qualified: AuditEvent is defined further down this file, and the
  # implicit alias a nested defmodule creates only exists after it.
  list_response(AdminAuditListResponse,
    of: FountainWeb.Schemas.AuditEvent,
    description: "Cross-tenant audit events; each carries the tenant it belongs to."
  )

  defmodule AccountDeleteRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AccountDeleteRequest",
      type: :object,
      properties: %{
        confirm: %Schema{
          type: :string,
          description: "The account's own email address, exactly."
        }
      },
      required: [:confirm]
    })
  end

  defmodule AccountDeletedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AccountDeletedResponse",
      type: :object,
      properties: %{
        deleted: %Schema{type: :boolean},
        user_id: %Schema{type: :string, format: :uuid},
        sprites_destroyed: %Schema{type: :integer}
      },
      required: [:deleted]
    })
  end

  defmodule AvatarRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AvatarRequest",
      description:
        "JSON form of an avatar upload. The raw-bytes form sends the image " <>
          "directly with an image content-type instead.",
      type: :object,
      properties: %{
        data: %Schema{type: :string, description: "Base64-encoded image bytes."},
        media_type: %Schema{
          type: :string,
          enum: ~w(image/png image/jpeg image/gif image/webp)
        }
      },
      required: [:data, :media_type]
    })
  end

  defmodule AuditEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEvent",
      description: "One entry in the account's append-only audit trail.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Cursor for `before`."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        actor: %Schema{
          type: :string,
          nullable: true,
          description:
            "Which surface acted: `ui` (browser session), `api` (bearer key), " <>
              "`sprite` (a per-conversation token held by a sandbox), `system`."
        },
        action: %Schema{type: :string, example: "vault.secret.write"},
        resource_type: %Schema{type: :string, nullable: true},
        resource_id: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        request_ip: %Schema{type: :string, nullable: true}
      },
      required: [:id, :action, :inserted_at]
    })
  end

  defmodule AuditEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEventListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: AuditEvent},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            has_more: %Schema{type: :boolean},
            next_cursor: %Schema{
              type: :integer,
              nullable: true,
              description: "Pass as `before` for the next (older) page."
            }
          },
          required: [:limit, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule InferenceCredentialStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialStatus",
      description:
        "Whether a provider credential is set for the tenant. Values are " <>
          "write-only — the API never returns a credential, truncated or otherwise.",
      type: :object,
      properties: %{
        provider: %Schema{
          type: :string,
          enum: ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)
        },
        set: %Schema{type: :boolean}
      },
      required: [:provider, :set]
    })
  end

  item_response(InferenceCredentialResponse, of: InferenceCredentialStatus)

  list_response(InferenceCredentialListResponse, of: InferenceCredentialStatus)

  defmodule InferenceCredentialRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialRequest",
      type: :object,
      properties: %{
        value: %Schema{
          type: :string,
          description: "The provider token (write-only)."
        },
        validate: %Schema{
          type: :boolean,
          default: true,
          description:
            "Ping the provider to check the credential before storing it. " <>
              "false stores it unchecked."
        }
      },
      required: [:value]
    })
  end

  defmodule HealthResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      type: :object,
      properties: %{status: %Schema{type: :string, example: "ok"}},
      required: [:status]
    })
  end

  defmodule ReadinessResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReadinessResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["ok", "error"], example: "ok"},
        checks: %Schema{
          type: :object,
          description: "Per-dependency result. `ok` or `error`, with no further detail.",
          additionalProperties: %Schema{type: :string, enum: ["ok", "error"]},
          example: %{"database" => "ok", "broker_listener" => "ok"}
        }
      },
      required: [:status, :checks]
    })
  end

  defmodule SearchHit do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SearchHit",
      description: "One search hit: what matched, and where to jump.",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: Fountain.Search.kinds()},
        conversation_id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        turn_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The turn (prompt / reply hits); null for a title hit."
        },
        turn_number: %Schema{type: :integer, nullable: true},
        snippet: %Schema{
          type: :string,
          description: "The best-matching fragment, plain text — no markup to escape."
        },
        ts: %Schema{
          type: :string,
          format: :"date-time",
          description: "The turn's creation time, or the conversation's for a title hit."
        }
      },
      required: [:kind, :conversation_id, :snippet, :ts]
    })
  end

  defmodule SearchResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SearchResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: SearchHit},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            offset: %Schema{type: :integer},
            has_more: %Schema{type: :boolean}
          },
          required: [:limit, :offset, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule CatalogResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CatalogResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sandbox_api_access: %Schema{
              type: :array,
              items: %Schema{type: :string, enum: ~w(owner none)}
            },
            runtimes: %Schema{type: :array, items: %Schema{type: :string}},
            models: %Schema{
              type: :object,
              additionalProperties: %Schema{type: :array, items: %Schema{type: :string}},
              description:
                "Suggested `provider/model` ids per runtime. Suggestions, not an allowlist."
            },
            model_providers: %Schema{type: :array, items: %Schema{type: :string}},
            sandbox_providers: %Schema{
              type: :object,
              properties: %{
                enabled: %Schema{type: :array, items: %Schema{type: :string}},
                default: %Schema{type: :string}
              },
              required: [:enabled, :default]
            },
            package_managers: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "The managers provisioning installs from an environment's `packages`."
            },
            apps: %Schema{
              type: :object,
              description:
                "Where this instance sends a human to watch a conversation. " <>
                  "Null for an app this deployment does not have.",
              properties: %{
                conversations: %Schema{type: :string, nullable: true}
              },
              required: [:conversations]
            },
            first_request: %Schema{
              type: :object,
              description:
                "The one quickstart request this deployment hands out, the same " <>
                  "text the manual and `managoat quickstart` print. The base " <>
                  "URL is already in it. The caller's key and agent are not: the " <>
                  "server stores only a hash of a key, so a client substitutes the " <>
                  "key it holds and an agent from `GET /api/agents`.",
              properties: %{
                curl: %Schema{type: :string, description: "The `curl`, with placeholders."},
                typescript: %Schema{
                  type: :string,
                  description: "The TypeScript SDK equivalent, with placeholders."
                },
                prompt: %Schema{
                  type: :string,
                  description: "The prompt both snippets send, for a client that runs it."
                },
                placeholders: %Schema{
                  type: :array,
                  items: %Schema{type: :string},
                  description: "Every token a client must substitute before it runs the request."
                }
              },
              required: [:curl, :typescript, :prompt, :placeholders]
            }
          },
          required: [
            :runtimes,
            :models,
            :sandbox_providers,
            :package_managers,
            :apps,
            :first_request
          ]
        }
      },
      required: [:data]
    })
  end

  defmodule OAuthTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthTokenRequest",
      type: :object,
      properties: %{
        grant_type: %Schema{
          type: :string,
          description: "`authorization_code` (anything else is 400 `unsupported_grant_type`)."
        },
        code: %Schema{
          type: :string,
          description: "The code from the `/oauth/authorize` redirect."
        },
        code_verifier: %Schema{
          type: :string,
          description: "The PKCE verifier whose S256 challenge was sent to `/oauth/authorize`."
        },
        client_id: %Schema{type: :string},
        redirect_uri: %Schema{
          type: :string,
          description: "Exactly the redirect_uri the authorization request used."
        }
      },
      required: [:grant_type, :code, :code_verifier, :client_id, :redirect_uri]
    })
  end

  defmodule OAuthTokenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthTokenResponse",
      type: :object,
      properties: %{
        access_token: %Schema{
          type: :string,
          description: "A Managoat API key; use it as the bearer token."
        },
        token_type: %Schema{type: :string, example: "bearer"},
        expires_in: %Schema{type: :integer, description: "Seconds until the key expires."}
      },
      required: [:access_token, :token_type, :expires_in]
    })
  end

  defmodule DeviceAuthResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceAuthResponse",
      description:
        "A fresh device-authorization grant (#1305). `device_code` stays on the " <>
          "polling machine and never gets typed; `user_code` is what the human " <>
          "enters at `verification_uri`.",
      type: :object,
      properties: %{
        device_code: %Schema{
          type: :string,
          description: "High-entropy code the CLI polls the token endpoint with. Shown once."
        },
        user_code: %Schema{
          type: :string,
          example: "BCDF-GHJK",
          description: "Short code for the human to type into the console."
        },
        verification_uri: %Schema{
          type: :string,
          description: "The console page where the user approves the grant."
        },
        verification_uri_complete: %Schema{
          type: :string,
          description: "`verification_uri` with the user code prefilled."
        },
        expires_in: %Schema{type: :integer, description: "Seconds until the grant expires."},
        interval: %Schema{
          type: :integer,
          description: "Minimum seconds between polls; faster gets `slow_down`."
        }
      },
      required: [
        :device_code,
        :user_code,
        :verification_uri,
        :verification_uri_complete,
        :expires_in,
        :interval
      ]
    })
  end

  defmodule DeviceAuthRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceAuthRequest",
      description: "Optional. An empty body, or none, starts a grant with no client name.",
      type: :object,
      properties: %{
        client_name: %Schema{
          type: :string,
          example: "Arugula on geek",
          description:
            "What the client calls itself. Shown, as the client's own unverified " <>
              "claim, on the approval page, and used as the minted API key's name " <>
              "(otherwise `CLI login — <date>`). Control, format and separator " <>
              "characters become single spaces, the result is trimmed and cut to " <>
              "64 characters, and nothing left counts as absent."
        }
      }
    })
  end

  defmodule DeviceTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceTokenRequest",
      type: :object,
      properties: %{
        device_code: %Schema{
          type: :string,
          description: "The `device_code` from `POST /api/auth/device`."
        }
      },
      required: [:device_code]
    })
  end

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Error",
      description:
        "The one body every JSON error status carries (#2324). `error` is the " <>
          "code to branch on; the other keys accompany particular codes and are " <>
          "absent otherwise. A `406` is the exception: content negotiation fails " <>
          "before any controller runs and renders `NegotiationError` instead.",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description:
            "The machine-readable code: `validation_failed`, `not_found`, " <>
              "`fleet_full`, `expired`, `insufficient_scope`, " <>
              "`invalid_token` and the rest. On the key-authentication refusals " <>
              "(401, and 403 `email_unverified`) it is a sentence and `reason` " <>
              "carries the code.",
          example: "validation_failed"
        },
        message: %Schema{type: :string, description: "A sentence for a human, when there is one."},
        reason: %Schema{
          type: :string,
          description:
            "A second stable word. On the key-authentication refusals, `error` is " <>
              "prose and this is the code (`api_key_invalid`, `api_key_expired`, " <>
              "`email_unverified`). On a 403 `insufficient_scope` it repeats " <>
              "`insufficient_scope`, where clients written before the scope refusals " <>
              "carried their code in `error` look for it."
        },
        required_scope: %Schema{
          type: :string,
          description:
            "Beside `error: \"insufficient_scope\"`: the key scope that is allowed " <>
              "the request, a `full` key such as one from `managoat auth login`."
        },
        depth: %Schema{
          type: :integer,
          description:
            "Beside `error: \"conversation_depth_exceeded\"`: the depth the refused " <>
              "conversation would have had in its spawn chain."
        },
        connection_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "Beside `error: \"connection_exists\"` and " <>
              "`error: \"connection_reconnect_required\"`: the connection meant."
        },
        max_depth: %Schema{
          type: :integer,
          description:
            "Beside `error: \"conversation_depth_exceeded\"`: the deepest this " <>
              "instance allows (`CONVERSATION_MAX_DEPTH`)."
        },
        errors: %Schema{
          type: :object,
          description:
            "Field validation messages keyed by field, beside " <>
              "`error: \"validation_failed\"`, whether the request died at the " <>
              "OpenAPI cast or in a changeset (#1431).",
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        }
      },
      required: [:error]
    })
  end

  defmodule ManifestResource do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ManifestResource",
      description:
        "One compiled document from a managoat.yml manifest. `spec` matches the " <>
          "create/update schema for the kind, plus an inline `secrets` map " <>
          "(Environment and Vault). Specs reference other documents by name, and " <>
          "the server resolves each to an id: an Agent's `environment`.",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          enum: ["Environment", "Vault", "Agent"]
        },
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        spec: %Schema{type: :object, additionalProperties: true}
      },
      required: [:kind, :name]
    })
  end

  defmodule ApplyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyRequest",
      type: :object,
      properties: %{
        resources: %Schema{type: :array, items: ManifestResource}
      },
      required: [:resources]
    })
  end

  defmodule ApplySecretResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplySecretResult",
      description: "Outcome for one secret key. Values are never echoed back.",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        action: %Schema{type: :string, enum: ["upserted", "error"]},
        errors: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      required: [:key, :action]
    })
  end

  defmodule ApplyResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyResult",
      type: :object,
      properties: %{
        kind: %Schema{type: :string},
        name: %Schema{type: :string},
        action: %Schema{
          type: :string,
          enum: ["created", "updated", "unchanged", "error"],
          description:
            "`unchanged` means the record already matched the document, so nothing " <>
              "was written to it and no audit event was recorded. Inline " <>
              "`spec.secrets` are re-encrypted on every apply and still report " <>
              "`upserted` under `secrets`."
        },
        errors: %Schema{type: :object, additionalProperties: true, nullable: true},
        secrets: %Schema{type: :array, items: ApplySecretResult}
      },
      required: [:kind, :name, :action]
    })
  end

  defmodule ApplyResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{results: %Schema{type: :array, items: ApplyResult}},
          required: [:results]
        }
      },
      required: [:data]
    })
  end

  defmodule MessageResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageResponse",
      type: :object,
      properties: %{message: %Schema{type: :string}},
      required: [:message]
    })
  end

  defmodule AuthTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthTokenRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password}
      },
      required: [:email, :password]
    })
  end

  defmodule AuthTokenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthTokenResponse",
      description: "A freshly minted full-scope key. `api_key` is shown once and never again.",
      type: :object,
      properties: %{
        api_key: %Schema{type: :string, example: "ftn_live_..."},
        key_id: %Schema{type: :string, format: :uuid},
        prefix: %Schema{
          type: :string,
          description: "Leading characters of the key, the only part stored in the clear."
        }
      },
      required: [:api_key, :key_id, :prefix]
    })
  end

  defmodule AuthMeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthMeResponse",
      description: "Identity of the account the bearer token belongs to.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string, format: :email},
        role: %Schema{type: :string, enum: ~w(user admin)},
        email_verified: %Schema{type: :boolean},
        brokered: %Schema{
          type: :boolean,
          description:
            "Always true: every conversation runs behind the egress credential " <>
              "broker (ADR 0019). Kept for clients that read it."
        },
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        conversation_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The conversation this key belongs to: the sandbox key a conversation " <>
              ~s(holds as MANAGOAT_TOKEN, or the `conversation`-scoped key an ) <>
              ~s(`"auth": "conversation"` MCP server receives as its bearer, which ) <>
              "reads that conversation and nothing else. Null for any other key, " <>
              "and for a sandbox key its conversation has rotated away."
        }
      },
      # These four are what `show/2` always renders. The list used to read
      # [:id, :name, :prefix, :created_at] — copied from ApiKey below, naming
      # three properties this schema does not have. Nothing caught it because
      # openapi-typescript drops a required name with no property, so the
      # generated client just had every field optional. The SDK contract
      # projection refuses to build such a schema, which is how it surfaced.
      required: [:id, :email, :role, :email_verified]
    })
  end

  defmodule ApiKey do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKey",
      description: "Key metadata. Never the key itself, and never its hash.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"},
        last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
        scopes: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "`full` for a key a person minted; `sprite` for the auto-issued " <>
              "token a sandbox holds; `conversation` for the key an " <>
              ~s(`"auth": "conversation"` MCP server receives, which reads its own ) <>
              "conversation and nothing else; `full` and `admin` for an admin " <>
              "key, the only key `/api/admin` admits."
        },
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :name, :prefix, :created_at]
    })
  end

  # ApiKey is referenced by the implicit alias the nested defmodule above
  # created; it only exists after that definition, hence the ordering.
  list_response(ApiKeyListResponse, of: ApiKey)

  defmodule OAuthClient do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthClient",
      description:
        "A tenant-owned OAuth client. Unpublished clients are in development " <>
          "mode and can sign in only their owner. Their redirect origins are " <>
          "also admitted by CORS.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        client_id: %Schema{
          type: :string,
          description: "The client_id sent to /oauth/authorize."
        },
        name: %Schema{type: :string, description: "Shown on the consent page."},
        redirect_uris: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Exact match, except that an unpublished loopback URI matches on any port."
        },
        origins: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Origins derived from redirect_uris and admitted by CORS. A " <>
              "loopback origin is admitted on any port, not only the port shown here."
        },
        published: %Schema{
          type: :boolean,
          description: "False means development mode with owner-only sign-in."
        },
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :client_id,
        :name,
        :redirect_uris,
        :origins,
        :published,
        :created_at,
        :updated_at
      ]
    })
  end

  defmodule OAuthClientRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthClientRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1},
        redirect_uris: %Schema{
          type: :array,
          items: %Schema{type: :string},
          minItems: 1
        }
      },
      required: [:name, :redirect_uris],
      example: %{
        name: "Notes",
        redirect_uris: ["https://abc123.sprites.app/callback", "http://localhost:5173/callback"]
      }
    })
  end

  defmodule OAuthClientUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthClientUpdateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1},
        redirect_uris: %Schema{
          type: :array,
          items: %Schema{type: :string},
          minItems: 1
        }
      },
      example: %{name: "Notes for Managoat"}
    })
  end

  list_response(OAuthClientListResponse, of: OAuthClient)

  defmodule Connection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Connection",
      description:
        "A user's OAuth grant to one remote MCP server (ADR 0085), named by the " <>
          "server's resource URL. An agent's `mcp_servers` entry names it as " <>
          ~S(`"auth": {"connection": id}`; the token reaches the server only ) <>
          "through the egress broker. Never carries a token or a client secret.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        url: %Schema{type: :string, description: "The server URL as it was entered."},
        resource: %Schema{
          type: :string,
          description:
            "The resource the server's metadata names. An agent entry's `url` must be " <>
              "this, on the same origin and path."
        },
        status: %Schema{
          type: :string,
          enum: Fountain.Connections.Connection.statuses(),
          description:
            "`pending`: consent not finished. `active`: holds a token. `revoked`: the " <>
              "provider refused a refresh for good. `expired`: the token lapsed with no " <>
              "refresh token. Every status but `active` needs a reconnect."
        },
        revoked_reason: %Schema{
          type: :string,
          nullable: true,
          description: "The provider's error code, when `revoked`."
        },
        issuer: %Schema{type: :string, description: "The authorization server."},
        registration: %Schema{
          type: :string,
          enum: Fountain.Connections.Connection.registrations(),
          description: "How Managoat got its client at the authorization server."
        },
        client_id: %Schema{type: :string},
        scopes: %Schema{type: :array, items: %Schema{type: :string}},
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the access token expires; null when the provider gave no expiry."
        },
        last_refreshed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :url,
        :resource,
        :status,
        :revoked_reason,
        :issuer,
        :registration,
        :client_id,
        :scopes,
        :expires_at,
        :last_refreshed_at,
        :created_at,
        :updated_at
      ]
    })
  end

  list_response(ConnectionListResponse, of: Connection)

  defmodule ConnectionRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConnectionRequest",
      type: :object,
      properties: %{
        url: %Schema{
          type: :string,
          description: "The remote MCP server's https URL, such as `https://mcp.linear.app/mcp`."
        },
        client_id: %Schema{
          type: :string,
          description:
            "A client you registered with the provider, for a server that lets no " <>
              "client register itself. Its redirect URI is " <>
              "`<PUBLIC_URL>/connections/callback`."
        },
        client_secret: %Schema{type: :string, description: "That client's secret, if it has one."},
        authorize_params: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description:
            "Extra parameters for the authorize request, such as Google's " <>
              "`access_type: offline` and `prompt: consent`. They cannot replace the " <>
              "flow's own parameters."
        }
      },
      required: [:url]
    })
  end

  defmodule ConnectionLogin do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConnectionLogin",
      type: :object,
      properties: %{
        connection: FountainWeb.Schemas.Connection,
        authorize_url: %Schema{
          type: :string,
          description:
            "Open this in a browser signed in to Managoat as the same account, within " <>
              "ten minutes."
        }
      },
      required: [:connection, :authorize_url]
    })
  end

  defmodule SecretBinding do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretBinding",
      description:
        "Which host a secret is attached to at the egress broker, and how " <>
          "(ADR 0019). Keyed by the secret's name: it applies wherever an " <>
          "environment or vault holds a secret of that name. A secret with at " <>
          "least one enabled binding reaches the sandbox as a placeholder " <>
          "(`__key__`); one with none reaches it in the clear.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string, description: "The secret's name, UPPER_SNAKE_CASE."},
        host: %Schema{
          type: :string,
          description:
            "Host pattern: `api.example.com`, a one-level wildcard `*.example.com`, " <>
              "optionally `:port` and a `/path/*` glob."
        },
        auth_type: %Schema{
          type: :string,
          enum: ["substitute", "bearer", "basic", "api_key", "custom"]
        },
        header: %Schema{
          type: :string,
          nullable: true,
          description: "api_key only: the header the value is sent in. Defaults to Authorization."
        },
        prefix: %Schema{
          type: :string,
          nullable: true,
          description: "api_key only: text placed before the value, such as `Token `."
        },
        username: %Schema{
          type: :string,
          nullable: true,
          description: "basic only: the username; the secret is the password."
        },
        headers: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description:
            "custom only: header name to template, `{{ KEY }}` is replaced by the secret."
        },
        enabled: %Schema{type: :boolean},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :host, :auth_type, :headers, :enabled, :created_at, :updated_at]
    })
  end

  defmodule SecretBindingRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretBindingRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        host: %Schema{type: :string},
        auth_type: %Schema{
          type: :string,
          enum: ["substitute", "bearer", "basic", "api_key", "custom"]
        },
        header: %Schema{type: :string, nullable: true},
        prefix: %Schema{type: :string, nullable: true},
        username: %Schema{type: :string, nullable: true},
        headers: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        enabled: %Schema{type: :boolean}
      },
      required: [:key, :host, :auth_type],
      example: %{key: "STRIPE_SECRET_KEY", host: "api.stripe.com", auth_type: "bearer"}
    })
  end

  defmodule SecretBindingPreset do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretBindingPreset",
      description: "A known service from the broker's catalog, to prefill a binding from.",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        host: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        auth_type: %Schema{type: :string},
        suggested_key: %Schema{type: :string, nullable: true},
        header: %Schema{type: :string, nullable: true},
        prefix: %Schema{type: :string, nullable: true},
        headers: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        usable: %Schema{
          type: :boolean,
          description:
            "False for the few presets a binding cannot express on its own (request signing, a username of yours)."
        }
      },
      required: [:id, :name, :host, :auth_type, :usable]
    })
  end

  defmodule EgressEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EgressEvent",
      description:
        "One outbound HTTP request the sandbox made through the egress broker " <>
          "(ADR 0019). The row is written when the request ends, so a streamed " <>
          "response is recorded when the stream finishes rather than when it starts.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        at: %Schema{type: :string, format: :"date-time", nullable: true},
        method: %Schema{type: :string},
        host: %Schema{type: :string, description: "Host and port, as the sandbox dialed it."},
        path: %Schema{
          type: :string,
          description:
            "Always /[REDACTED]. URL paths, queries and fragments are withheld because they can contain credentials."
        },
        service: %Schema{
          type: :string,
          nullable: true,
          description:
            "The binding that matched, and so which credential was attached. Null when " <>
              "none was: a passthrough host, or a host allowed under `limited` with no " <>
              "credential bound to it."
        },
        credential_keys: %Schema{type: :array, items: %Schema{type: :string}},
        status: %Schema{
          type: :integer,
          nullable: true,
          description:
            "The upstream status, or the broker's own refusal. Null where no answer arrived."
        },
        latency_ms: %Schema{
          type: :integer,
          nullable: true,
          description:
            "How long the whole request took, request head through response body, " <>
              "not time to first byte."
        },
        error: %Schema{
          type: :string,
          nullable: true,
          description:
            "Why forwarding did not complete, such as `upstream_closed`, " <>
              "`credential_missing` or `request_timeout`. Null on a request that did."
        }
      },
      required: [:id, :method, :host, :path, :credential_keys]
    })
  end

  defmodule EgressListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EgressListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: EgressEvent},
        next: %Schema{
          type: :integer,
          nullable: true,
          description: "Pass as `before` for the next page; null at the end."
        },
        brokered: %Schema{
          type: :boolean,
          description:
            "Always true: every conversation is brokered. Kept for clients that read it."
        }
      },
      required: [:data, :brokered]
    })
  end

  list_response(SecretBindingListResponse, of: SecretBinding)
  list_response(SecretBindingPresetListResponse, of: SecretBindingPreset)

  defmodule ApiKeyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, description: "What this key is for."}
      },
      required: [:name]
    })
  end

  defmodule ApiKeyCreatedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyCreatedResponse",
      description: "The one and only response that carries key material.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        key: %Schema{type: :string, description: "Plaintext key. Not recoverable afterwards."},
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :key, :prefix]
    })
  end

  defmodule RegisterRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password}
      },
      required: [:email, :password]
    })
  end

  defmodule RegisterResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterResponse",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        message: %Schema{type: :string}
      },
      required: [:user_id, :message]
    })
  end

  defmodule EmailRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailRequest",
      type: :object,
      properties: %{email: %Schema{type: :string, format: :email}},
      required: [:email]
    })
  end

  defmodule TokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenRequest",
      description: "A token lifted out of an emailed link.",
      type: :object,
      properties: %{token: %Schema{type: :string}},
      required: [:token]
    })
  end

  defmodule VerifyEmailResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VerifyEmailResponse",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        email_verified: %Schema{type: :boolean},
        message: %Schema{type: :string}
      },
      required: [:user_id, :email_verified, :message]
    })
  end

  defmodule PasswordResetRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordResetRequest",
      type: :object,
      properties: %{
        token: %Schema{type: :string, description: "From the reset email."},
        password: %Schema{type: :string, format: :password}
      },
      required: [:token, :password]
    })
  end

  defmodule PasswordChangeRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordChangeRequest",
      type: :object,
      properties: %{
        current_password: %Schema{type: :string, format: :password},
        new_password: %Schema{type: :string, format: :password}
      },
      required: [:current_password, :new_password]
    })
  end

  defmodule PasswordChangeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordChangeResponse",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        sessions_invalidated: %Schema{type: :boolean},
        api_keys_revoked: %Schema{
          type: :boolean,
          description:
            "Always false. API keys are separate credentials with their own " <>
              "expiries; revoke them yourself at `DELETE /api/auth/api-keys/{id}`."
        }
      },
      required: [:message, :sessions_invalidated, :api_keys_revoked]
    })
  end
end
