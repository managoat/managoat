defmodule FountainWeb.SchemaEnumGuardrailTest do
  @moduledoc """
  The OpenAPI enums against the domain lists they restate (issue #599).

  `FountainWeb.Schemas` declares every enum a second time, by hand. Twelve
  lists were duplicated verbatim from an Ecto schema — `agent.runtime` alone
  in four places — and nothing checked that the copies agreed. The drift is
  silent in the worst direction: add a value to `@statuses` and the changeset
  accepts it, the API returns it, the spec says it cannot exist,
  `mix openapi.spec.json` still passes, and only a generated client with a
  strict enum decoder finds out, in production. #197 is the precedent — the
  unreachable `completed` conversation status stayed in the published enum
  after the schema dropped it.

  This walks every `FountainWeb.Schemas.*` module, finds every property
  carrying an `:enum`, and requires each one to be either

    * mapped in `@derived` to the domain function that owns the list, and
      equal to it; or
    * listed in `@api_local` with a reason — an enum with no domain
      counterpart, which is a decision rather than an oversight.

  Add an enum to a schema and this test fails until you do one or the other.
  Comparison is by set: OpenAPI enum order is not meaningful, and two of
  these lists were already written in a different order than their source
  (`~w(admin user)` against `User.roles/0`'s `~w(user admin)`).
  """

  use ExUnit.Case, async: true

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}
  alias Fountain.Environments.Environment
  alias Fountain.InferenceCredentials.Credential
  alias Fountain.{Images, Manifest}
  alias OpenApiSpex.Schema

  # {schema module, dotted property path} => {owning module, function}
  #
  # The value is compared as a set against `apply(mod, fun, [])`. A provider
  # list of atoms is stringified first — the domain keeps them as atoms, the
  # wire carries strings.
  @derived %{
    {FountainWeb.Schemas.Sandbox, "transition"} => {Sandbox, :transitions},
    {FountainWeb.Schemas.SandboxDetail, "transition"} => {Sandbox, :transitions},
    {FountainWeb.Schemas.Connection, "status"} => {Fountain.Connections.Connection, :statuses},
    {FountainWeb.Schemas.Connection, "registration"} =>
      {Fountain.Connections.Connection, :registrations},
    {FountainWeb.Schemas.Conversation, "sandbox_api_access"} =>
      {Conversation, :sandbox_api_access_modes},
    {FountainWeb.Schemas.ConversationCreateRequest, "sandbox_api_access"} =>
      {Conversation, :sandbox_api_access_modes},
    {FountainWeb.Schemas.CatalogResponse, "data.sandbox_api_access.[]"} =>
      {Conversation, :sandbox_api_access_modes},
    # Which source served a turn (ADR 0060 decision 6), from the stored source.
    {FountainWeb.Schemas.Turn, "inference.scope"} =>
      {Fountain.InferenceCredentials.Source, :scopes},
    # Sandbox files (ADR 0039): what the listing script classifies an entry
    # as, and how a file's bytes travel.
    {FountainWeb.Schemas.SandboxEntry, "type"} => {Fountain.SandboxFiles, :entry_types},
    {FountainWeb.Schemas.SandboxFile, "encoding"} => {Fountain.SandboxFiles, :encodings},
    # `git status`: the porcelain letters in words, and what a caller may ask
    # about untracked paths.
    {FountainWeb.Schemas.SandboxChange, "index"} => {Fountain.SandboxFiles, :change_states},
    {FountainWeb.Schemas.SandboxChange, "worktree"} => {Fountain.SandboxFiles, :change_states},
    {FountainWeb.Schemas.SandboxStatus, "untracked"} => {Fountain.SandboxFiles, :untracked_modes},
    {FountainWeb.Schemas.AdminRoleRequest, "role"} => {User, :roles},
    {FountainWeb.Schemas.AdminUser, "role"} => {User, :roles},
    {FountainWeb.Schemas.AuthMeResponse, "role"} => {User, :roles},
    # The four Fountain ships, and the only ones the published contract names.
    # Sandbox providers distinguish known_providers/0 from enabled_providers/0.
    # Responses carry no enum for a runtime or a
    # provider: rows from before opencode and Daytona were removed (2026-10)
    # still name them.
    {FountainWeb.Schemas.AgentRequest, "runtime"} => {Agent, :packaged_runtimes},
    {FountainWeb.Schemas.AgentUpdate, "runtime"} => {Agent, :packaged_runtimes},
    {FountainWeb.Schemas.Agent, "sandbox_provider"} =>
      {Fountain.SandboxProviders, :known_providers},
    {FountainWeb.Schemas.AgentRequest, "sandbox_provider"} =>
      {Fountain.SandboxProviders, :known_providers},
    {FountainWeb.Schemas.AgentUpdate, "sandbox_provider"} =>
      {Fountain.SandboxProviders, :known_providers},
    {FountainWeb.Schemas.Agent, "avatar_media_type"} => {Images, :valid_media_types},
    {FountainWeb.Schemas.AvatarRequest, "media_type"} => {Images, :valid_media_types},
    {FountainWeb.Schemas.ImageInput, "media_type"} => {Images, :valid_media_types},
    # The permission verdicts a policy may actually name today. Deliberately
    # `buildable_verdicts/0` and not `verdicts/0`: "ask" is a real verdict the
    # domain knows about, with nowhere to ask until #940, and both doors refuse
    # it — so publishing it in the spec would advertise a value every request
    # carrying it gets a 422 for.
    # One entry, not five: the five call sites reference the PermissionPolicy
    # schema module (#1899), so the enum is declared once and `walk/2` sees it
    # only there — a module reference is that module's own responsibility.
    {FountainWeb.Schemas.PermissionPolicy, "{}"} =>
      {Managoat.ACP.Permissions, :buildable_verdicts},
    {FountainWeb.Schemas.Conversation, "status"} => {Conversation, :statuses},
    {FountainWeb.Schemas.Conversation, "source"} => {Conversation, :sources},
    {FountainWeb.Schemas.ConversationTreeNode, "status"} => {Conversation, :statuses},
    {FountainWeb.Schemas.ConversationTreeNode, "source"} => {Conversation, :sources},
    {FountainWeb.Schemas.Environment, "networking_type"} => {Environment, :networking},
    {FountainWeb.Schemas.EnvironmentRequest, "networking_type"} => {Environment, :networking},
    {FountainWeb.Schemas.EnvironmentUpdate, "networking_type"} => {Environment, :networking},
    {FountainWeb.Schemas.InferenceCredentialStatus, "provider"} => {Credential, :providers},
    {FountainWeb.Schemas.LogEvent, "kind"} => {LogEvent, :kinds},
    {FountainWeb.Schemas.LogEvent, "state"} => {LogEvent, :states},
    # StreamLogEvent (#2297) reuses LogEvent's own property map for these,
    # so the same domain lists apply.
    {FountainWeb.Schemas.StreamLogEvent, "kind"} => {LogEvent, :kinds},
    {FountainWeb.Schemas.StreamLogEvent, "state"} => {LogEvent, :states},
    {FountainWeb.Schemas.ManifestResource, "kind"} => {Manifest, :kinds},
    {FountainWeb.Schemas.Sandbox, "status"} => {Sandbox, :statuses},
    # A workspace's provision outcome (ADR 0097), on the resource and the event.
    {FountainWeb.Schemas.Workspace, "status"} => {Fountain.Workspaces.Workspace, :statuses},
    {FountainWeb.Schemas.StreamWorkspaceStatus, "status"} =>
      {Fountain.Workspaces.Workspace, :statuses},
    # The environment fields a machine is built from (#2987), which
    # `changed_fields` names.
    {FountainWeb.Schemas.Workspace, "changed_fields.[]"} =>
      {Fountain.Workspaces.Staleness, :field_names},
    {FountainWeb.Schemas.StreamWorkspaceStatus, "changed_fields.[]"} =>
      {Fountain.Workspaces.Staleness, :field_names},
    # A workspace's setup (#3009): the steps it reports and a setup's status,
    # on the workspace, its log, the log's steps and the live event.
    {FountainWeb.Schemas.Workspace, "setup_step"} => {Fountain.Workspaces.SetupOutput, :steps},
    {FountainWeb.Schemas.WorkspaceSetupLog, "step"} => {Fountain.Workspaces.SetupOutput, :steps},
    {FountainWeb.Schemas.WorkspaceSetupLog, "status"} =>
      {Fountain.Workspaces.SetupLog, :statuses},
    {FountainWeb.Schemas.WorkspaceSetupStep, "step"} => {Fountain.Workspaces.SetupOutput, :steps},
    {FountainWeb.Schemas.WorkspaceSetupStep, "status"} =>
      {Fountain.Workspaces.SetupLog, :statuses},
    {FountainWeb.Schemas.StreamWorkspaceSetup, "step"} =>
      {Fountain.Workspaces.SetupOutput, :steps},
    {FountainWeb.Schemas.StreamWorkspaceSetup, "status"} =>
      {Fountain.Workspaces.SetupLog, :statuses},
    # The sandbox listing (ADR 0023 gate 3): a sandbox with its conversations.
    {FountainWeb.Schemas.SandboxDetail, "status"} => {Sandbox, :statuses},
    {FountainWeb.Schemas.SandboxConversation, "status"} => {Conversation, :statuses},
    {FountainWeb.Schemas.Turn, "status"} => {Turn, :statuses},
    {FountainWeb.Schemas.Turn, "origin"} => {Turn, :origins},
    {FountainWeb.Schemas.Block, "kind"} => {Fountain.Conversations.Blocks, :kinds},
    # The three answers to an ACP form (#2492), from the module that checks them.
    {FountainWeb.Schemas.PermissionAnswerRequest, "action"} =>
      {Managoat.ACP.Elicitation, :actions},
    {FountainWeb.Schemas.SearchHit, "kind"} => {Fountain.Search, :kinds},
    # Secret bindings (ADR 0019 gate 1b): the auth shapes the broker can carry.
    {FountainWeb.Schemas.SecretBinding, "auth_type"} =>
      {Fountain.SecretBindings.Binding, :auth_types},
    {FountainWeb.Schemas.SecretBindingRequest, "auth_type"} =>
      {Fountain.SecretBindings.Binding, :auth_types}
  }

  @legacy_mode "deprecated sandbox mode (ADR 0073); no domain list, every sandbox is ephemeral"

  # Enums with no domain list behind them. Each entry needs a reason: the
  # point of the list is that adding to it is a deliberate act.
  @api_local %{
    # The sandbox mode, deprecated with persistent homes (ADR 0073): every
    # sandbox is ephemeral, and the API still names both for older clients.
    {FountainWeb.Schemas.Sandbox, "mode"} => @legacy_mode,
    {FountainWeb.Schemas.SandboxDetail, "mode"} => @legacy_mode,
    {FountainWeb.Schemas.ConversationCreateRequest, "sandbox_mode"} => @legacy_mode,
    {FountainWeb.Schemas.Agent, "sandbox_mode"} => @legacy_mode,
    {FountainWeb.Schemas.AgentRequest, "sandbox_mode"} => @legacy_mode,
    {FountainWeb.Schemas.AgentUpdate, "sandbox_mode"} => @legacy_mode,
    {FountainWeb.Schemas.ConversationWakeResponse, "status"} =>
      "What a wake request did (awake: a server was already running; waking: it started one); not stored state",
    {FountainWeb.Schemas.LogEventListResponse, "page.order"} =>
      "Echo of the events read's `order` query parameter (#2531); a paging direction, not domain state",
    {FountainWeb.Schemas.Block, "body.[].status"} =>
      "ACP PlanEntryStatus wire vocabulary; no Fountain domain list or upstream enum accessor",
    {FountainWeb.Schemas.UsageAccounting, "completeness"} =>
      "Adapter claim validated by Managoat.ACP.Usage; the library exposes no enum accessor",
    {FountainWeb.Schemas.Turn, "model_selection.status"} =>
      "ACP selection outcomes built per report in TurnMachine",
    {FountainWeb.Schemas.Turn, "model_selection.source"} =>
      "ACP peer evidence: a runtime model field or a setter acknowledgement",
    # Outcomes of an admin action. Computed in the controller from what the
    # action did; they describe an HTTP response, not a stored value.
    {FountainWeb.Schemas.AdminReapResponse, "data.outcome"} =>
      "admin reap result — response vocabulary, not persisted state",
    # Per-resource results from `managoat apply`. Manifest reports these as
    # atoms built inline per branch; there is no list to compare against.
    {FountainWeb.Schemas.ApplyResult, "action"} =>
      "manifest apply outcome — built per branch in Manifest, not a declared list",
    {FountainWeb.Schemas.ApplySecretResult, "action"} =>
      "manifest secret apply outcome — as above",
    # Health probe vocabulary, owned by the readiness endpoint.
    {FountainWeb.Schemas.ReadinessResponse, "status"} => "health probe vocabulary",
    {FountainWeb.Schemas.ReadinessResponse, "checks.{}"} => "health probe vocabulary",
    # The one value every stream signal frame carries (#2297); events_controller.ex
    # and team_controller.ex build the literal inline, so there is no domain list.
    {FountainWeb.Schemas.StreamSignal, "reason"} =>
      "fixed SSE signal-frame vocabulary — built as a literal at each call site"
  }

  # Domain lists that are exposed on the wire but deliberately carry no enum
  # in the spec. Recorded here so the omission stays a decision — this test
  # cannot catch drift in a field it does not constrain.
  #
  #   LogEvent.stream (LogEvent.streams/0 == ~w(stdout stderr)) — stage events
  #   carry "" for this field, so the honest enum would be
  #   ["stdout", "stderr", ""]. Left unconstrained with a prose description
  #   instead. Revisit if stage events stop sharing the shape.

  describe "every OpenAPI enum is accounted for" do
    setup do
      %{sites: enum_sites()}
    end

    test "each enum matches the domain list it restates", %{sites: sites} do
      mismatches =
        for {mod, path, enum} <- sites,
            {owner, fun} = Map.get(@derived, {mod, path}, {nil, nil}),
            owner != nil,
            expected = owner |> apply(fun, []) |> Enum.map(&to_string/1) |> MapSet.new(),
            actual = enum |> Enum.map(&to_string/1) |> MapSet.new(),
            not MapSet.equal?(expected, actual) do
          """
            #{short(mod)}.#{path}
              spec has:   #{inspect(Enum.sort(actual))}
              #{inspect(owner)}.#{fun}/0 has: #{inspect(Enum.sort(expected))}
              only in spec:   #{inspect(actual |> MapSet.difference(expected) |> Enum.sort())}
              only in domain: #{inspect(expected |> MapSet.difference(actual) |> Enum.sort())}
          """
        end

      assert mismatches == [],
             "OpenAPI enums have drifted from the domain lists they restate:\n\n" <>
               Enum.join(mismatches, "\n")
    end

    test "no enum is unclassified", %{sites: sites} do
      unclassified =
        for {mod, path, enum} <- sites,
            not Map.has_key?(@derived, {mod, path}),
            not Map.has_key?(@api_local, {mod, path}),
            do: "  #{short(mod)}.#{path} => #{inspect(enum)}"

      assert unclassified == [],
             """
             New OpenAPI enum(s) with no declared source:

             #{Enum.join(unclassified, "\n")}

             Add each to @derived pointing at the domain function that owns the
             list, or to @api_local with a reason if it has no domain counterpart.
             """
    end

    test "the registries have no stale entries", %{sites: sites} do
      live = MapSet.new(sites, fn {mod, path, _} -> {mod, path} end)

      stale =
        (Map.keys(@derived) ++ Map.keys(@api_local))
        |> Enum.reject(&MapSet.member?(live, &1))
        |> Enum.map(fn {mod, path} -> "  #{short(mod)}.#{path}" end)

      assert stale == [],
             "Registry entries pointing at enums that no longer exist:\n" <>
               Enum.join(stale, "\n")
    end
  end

  # Every enum reachable from a schema, as {module, dotted path, values}.
  defp enum_sites do
    :fountain
    |> :application.get_key(:modules)
    |> elem(1)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.FountainWeb.Schemas."))
    |> Enum.sort()
    |> Enum.flat_map(fn mod ->
      Code.ensure_loaded(mod)

      if function_exported?(mod, :schema, 0) do
        mod.schema() |> walk([]) |> Enum.map(fn {path, enum} -> {mod, path, enum} end)
      else
        []
      end
    end)
  end

  # `properties` values may be a %Schema{}, a nested schema module (a $ref),
  # or a bare type atom. Only inline %Schema{} structs are walked — a module
  # reference is that module's own responsibility and is visited on its own.
  defp walk(%Schema{} = schema, path) do
    own =
      if is_list(schema.enum),
        do: [{path |> Enum.reverse() |> Enum.join("."), schema.enum}],
        else: []

    own ++
      walk_props(schema.properties, path) ++
      walk(schema.items, ["[]" | path]) ++
      walk(schema.additionalProperties, ["{}" | path]) ++
      Enum.flat_map(schema.oneOf || [], &walk(&1, path)) ++
      Enum.flat_map(schema.allOf || [], &walk(&1, path))
  end

  defp walk(_, _), do: []

  defp walk_props(props, path) when is_map(props),
    do: Enum.flat_map(props, fn {key, value} -> walk(value, [to_string(key) | path]) end)

  defp walk_props(_, _), do: []

  defp short(mod), do: mod |> inspect() |> String.replace("FountainWeb.Schemas.", "")
end
