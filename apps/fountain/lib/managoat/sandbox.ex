defmodule Managoat.Sandbox do
  @moduledoc """
  The sandbox backend contract: one behaviour, one facade, one error taxonomy.

  A sandbox is a machine an agent runs in, owned by a *provider* (Sprites
  and E2B ship here; a test can register more). This module is both
  the `@behaviour` an adapter implements and the facade a host application
  calls — call sites never name an adapter module, they dispatch through
  here on either a provider atom (creation-side operations) or the
  `provider` tag carried by a `Managoat.Sandbox.Handle` /
  `Managoat.Sandbox.Command`.

  The semantics below are normative for every adapter;
  `Managoat.Sandbox.ConformanceCase` pins them, and `Managoat.Sandbox.Fake`
  is the reference implementation.

  ## Lifecycle semantics

    * `c:create/2` is **name-keyed and idempotent-adopting**: creating a name
      that already exists returns `{:ok, handle}` for the existing sandbox.
    * `c:get/1` must return `{:error, :not_found}` for a definitively absent
      sandbox and a *different* error for anything transient. Callers use the
      distinction to decide whether a parked disk (holding agent memory) may
      be given up — misclassifying a network blip as not-found loses data.
    * `c:destroy/1` tolerates an already-gone sandbox (`:ok`).
    * `c:list_all_names/0` returns the full account view or refuses with
      `{:error, :truncated}` — never a partial set that looks whole.
    * `c:suspend/1` / `c:resume/1` park and wake a sandbox. Adapters whose
      platform parks implicitly (scale-to-zero) implement them as no-ops but
      still advertise `:suspend` — the flag answers "does idle parking
      preserve the disk cheaply?", and the idle sweep destroys instead where
      it is absent. A failed suspend call degrades to destroy (an unparked
      sandbox keeps billing); a failed resume leaves the row suspended (the
      disk is the agent's memory).

  ## Exec semantics

    * `c:exec/4` blocks until the command exits and **never raises**: a
      nonzero exit is `{:ok, output, code}` (the script failed — readable),
      an unreachable sandbox is `{:error, reason}` (retriable by the caller).
      With `on_output: fun`, an adapter that streams calls `fun.(chunk)` in
      the caller's process for each output chunk as it arrives (stderr too,
      under `:stderr_to_stdout`) and leaves those chunks out of the returned
      `output`, so the caller holds no copy of a long run. An adapter that
      cannot stream ignores the option and returns everything at exit; a
      caller that handles both treats `chunks <> output` as the whole output.
    * `c:spawn/4` starts a streaming command. The adapter must deliver these
      messages, and only these, to the `:owner` pid:

          {:stdout, %{ref: ref}, data :: binary()}
          {:stderr, %{ref: ref}, data :: binary()}   # absent in tty mode
          {:exit,   %{ref: ref}, exit_code :: integer()}
          {:error,  %{ref: ref}, reason :: term()}   # transport failure; no :exit follows

      where `ref` equals the returned command's `ref` and the second element
      is any map carrying `:ref` — consumers must match `%{ref: ref}`, never
      an adapter's struct. Exactly one terminal frame (`:exit` or `:error`)
      arrives, after all output frames. **A stream that closes without an
      exit frame is `{:error, %{ref: ref}, :closed_before_exit}`, never a
      synthesised `{:exit, %{ref: ref}, 0}`** — the command's fate is
      unknown, and reporting an unknown fate as success is how a failed
      setup script reads as a clean run (#880). An adapter that can still
      recover the real code after the close (a shim's exit file, say) sends
      the `:exit` frame it recovered; what it must never do is fabricate one.
    * `c:write_stdin/2` is **total**: writing to a command whose process has
      already exited returns `{:error, :command_exited}`, it never exits or
      raises in the caller (the #603 contract).
    * `c:attach/3` re-joins a detached session and **replays its buffered
      output from the beginning, then tails**. There is no offset parameter;
      callers de-duplicate by counting bytes already persisted per stream,
      which only works if replay starts at byte zero.

  ## Errors

  Adapters normalize provider error shapes into the closed `t:error/0`
  taxonomy so retry classification (`Managoat.Sandbox.Retry.transient?/1`) and
  not-found handling are provider-neutral.
  """

  alias Managoat.Sandbox.{Command, Handle, NetworkPolicy, Session}

  @typedoc "A sandbox backend identifier."
  @type provider :: atom()

  @typedoc "The Fountain-minted, provider-scoped sandbox name."
  @type name :: String.t()

  @typedoc """
  What a provider can do beyond the required operations.

    * `:suspend` — idle sandboxes can park with their disk preserved at
      negligible cost (implicitly via scale-to-zero, or via an explicit
      pause/stop call in `c:suspend/1`); the idle sweep destroys instead
      where absent
    * `:network_policy` — deny-capable egress policy
    * `:attach` — detachable sessions with replay-from-start
    * `:tty` — PTY allocation on spawn
    * `:public_url` — the platform gives each sandbox an HTTP endpoint, and
      the adapter can report it (and make it reachable without a platform
      credential). Agents serve from inside the sandbox and need to be able to
      tell a human where to look
  """
  @type capability ::
          :suspend
          | :network_policy
          | :attach
          | :tty
          | :public_url

  @typedoc """
  The provider-neutral error taxonomy.

    * `:not_found` — the sandbox/session definitively does not exist
    * `:truncated` — a listing refused to return a partial view
    * `:not_supported` — the adapter does not implement this operation
    * `:command_exited` — stdin write raced the command's exit
    * `{:rate_limited, retry_after}` — throttled; transient
    * `{:unavailable, detail}` — 5xx / timeout / transport; transient
    * `{:denied, detail}` — 401/403; a credential problem, permanent
    * `{:invalid, detail}` — other 4xx; the caller's fault, permanent
    * `{:write_failed, detail}` — stdin write failed for a non-exit reason
    * `{:provider, provider, detail}` — escape hatch; classified transient
  """
  @type error ::
          :not_found
          | :truncated
          | :not_supported
          | :command_exited
          | {:rate_limited, non_neg_integer() | nil}
          | {:unavailable, term()}
          | {:denied, term()}
          | {:invalid, term()}
          | {:write_failed, term()}
          | {:provider, provider(), term()}

  @typedoc "Normalized sandbox info from `c:get/1`. `:raw` is provider-shaped."
  @type info :: %{status: :running | :suspended | :unknown, raw: term()}

  # ── behaviour ──────────────────────────────────────────────────────────────

  @doc "The provider atom this adapter serves."
  @callback provider() :: provider()

  @doc "Capabilities this adapter currently offers (may be config-dependent)."
  @callback capabilities() :: MapSet.t(capability())

  @doc "Build a handle from a persisted name. Pure — no I/O."
  @callback build_handle(name()) :: Handle.t()

  @doc "Create (or adopt) the named sandbox."
  @callback create(name(), keyword()) :: {:ok, Handle.t()} | {:error, error()}

  @doc "Probe the sandbox. `{:error, :not_found}` is definitive absence."
  @callback get(Handle.t()) :: {:ok, info()} | {:error, error()}

  @doc "Destroy the sandbox. Already-gone is `:ok`."
  @callback destroy(Handle.t()) :: :ok | {:error, error()}

  @doc "Every sandbox name on the account, or a refusal — never a partial view."
  @callback list_all_names() :: {:ok, MapSet.t(name())} | {:error, error()}

  @doc "Explicitly park the sandbox. No-op where the platform parks implicitly."
  @callback suspend(Handle.t()) :: :ok | {:error, error()}

  @doc "Wake a parked sandbox, returning a fresh handle."
  @callback resume(Handle.t()) :: {:ok, Handle.t()} | {:error, error()}

  @doc "Write a file (creating parent directories). Options: `:mode`."
  @callback write_file(Handle.t(), path :: String.t(), iodata(), keyword()) ::
              :ok | {:error, error()}

  @doc """
  Run a command to completion. Options: `:env` (list of `{key, value}`
  pairs), `:dir`, `:timeout` (ms, default `:infinity`), `:stderr_to_stdout`,
  `:on_output` (see the moduledoc's exec semantics).
  """
  @callback exec(Handle.t(), cmd :: String.t(), args :: [String.t()], keyword()) ::
              {:ok, output :: binary(), exit_code :: integer()} | {:error, error()}

  @doc """
  Start a streaming command. Options: `:owner`, `:env`, `:dir`, `:stdin`,
  `:tty`, `:detachable`. Messages per the moduledoc contract.
  """
  @callback spawn(Handle.t(), cmd :: String.t(), args :: [String.t()], keyword()) ::
              {:ok, Command.t()} | {:error, error()}

  @doc "Write to the command's stdin. Total — see the moduledoc."
  @callback write_stdin(Command.t(), iodata()) :: :ok | {:error, error()}

  @doc "Send stdin EOF."
  @callback close_stdin(Command.t()) :: :ok | {:error, error()}

  @doc """
  Stop the local command handle, terminating its transport. Total — an
  already-stopped command is `:ok`. For a detachable command the remote
  process keeps running (that is what reattach exists for); this only tears
  down this node's end.
  """
  @callback stop_command(Command.t()) :: :ok

  @doc "List the sandbox's detachable sessions."
  @callback list_sessions(Handle.t()) :: {:ok, [Session.t()]} | {:error, error()}

  @doc "Re-join a detached session; replays buffered output from the start."
  @callback attach(Handle.t(), session_id :: String.t(), keyword()) ::
              {:ok, Command.t()} | {:error, error()}

  @doc "Apply a deny-capable egress policy. `allow: []` must deny all egress."
  @callback apply_network_policy(Handle.t(), NetworkPolicy.t()) :: :ok | {:error, error()}

  @doc """
  Whether `policy` is already the sandbox's egress policy, as the provider
  reports it. Optional: `ensure_network_policy/2` writes the policy on an
  adapter without it. Anything short of a definite match, a failed read
  included, answers `false`, so the caller writes.
  """
  @callback network_policy_in_force?(Handle.t(), NetworkPolicy.t()) :: boolean()

  @optional_callbacks network_policy_in_force?: 2

  @doc """
  The sandbox's HTTP endpoint, or `{:error, :unsupported}` where the platform
  has no such concept.

  Adapters that advertise `:public_url` must return a URL a browser can open.
  Everything else returns `{:error, :unsupported}` rather than a guess: a URL
  that does not resolve is worse than none, because the agent will hand it to
  a human who then blames the service they were told to visit.
  """
  @callback public_url(Handle.t()) :: {:ok, String.t()} | {:error, :unsupported | error()}

  # ── facade ─────────────────────────────────────────────────────────────────

  @default_adapters %{
    sprites: Managoat.Sandbox.Sprites,
    e2b: Managoat.Sandbox.E2B
  }

  @doc """
  The adapter map: provider atom to the module implementing this behaviour.

  Defaults to the two adapters that ship here, Sprites and E2B. A test
  registers another (an in-memory fake) by setting the whole map:

      config :fountain, :sandbox_adapters,
        %{sprites: Managoat.Sandbox.Sprites, mine: MyApp.SandboxAdapter}

  Which of these a deployment may *use* is `Fountain.SandboxProviders`'
  question: a credential being present, an operator opt-out. This answers
  only "which module serves this atom".
  """
  @spec adapters() :: %{provider() => module()}
  def adapters, do: Application.get_env(:fountain, :sandbox_adapters, @default_adapters)

  @doc "The adapter module for a provider. Raises on an unknown provider."
  @spec adapter_for(provider()) :: module()
  def adapter_for(provider) when is_atom(provider) do
    adapters = adapters()

    case Map.fetch(adapters, provider) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown sandbox provider #{inspect(provider)} — configured: " <>
                inspect(Map.keys(adapters))
    end
  end

  @doc "Whether a provider (or the provider owning a handle) has a capability."
  @spec supports?(provider() | Handle.t(), capability()) :: boolean()
  def supports?(%Handle{provider: provider}, capability), do: supports?(provider, capability)

  def supports?(provider, capability) when is_atom(provider) do
    MapSet.member?(adapter_for(provider).capabilities(), capability)
  end

  @doc "Build a handle for a persisted sandbox name. Pure — no I/O."
  @spec build_handle(provider(), name()) :: Handle.t()
  def build_handle(provider, name), do: adapter_for(provider).build_handle(name)

  @doc "Create (or adopt) a sandbox on the given provider."
  @spec create(provider(), name(), keyword()) :: {:ok, Handle.t()} | {:error, error()}
  def create(provider, name, opts \\ []), do: adapter_for(provider).create(name, opts)

  @doc "Every sandbox name the provider's account holds."
  @spec list_all_names(provider()) :: {:ok, MapSet.t(name())} | {:error, error()}
  def list_all_names(provider) when is_atom(provider) do
    adapter_for(provider).list_all_names()
  end

  @doc "Probe a sandbox."
  @spec get(Handle.t()) :: {:ok, info()} | {:error, error()}
  def get(%Handle{} = handle), do: adapter(handle).get(handle)

  @doc "Destroy a sandbox."
  @spec destroy(Handle.t()) :: :ok | {:error, error()}
  def destroy(%Handle{} = handle), do: adapter(handle).destroy(handle)

  @doc """
  The sandbox's HTTP endpoint.

  `{:error, :unsupported}` when the provider has none — callers treat that as
  "no URL to report", not as a failure. It is deliberately outside the shared
  error taxonomy: every other error means something went wrong, and this one
  means the question does not apply.
  """
  @spec public_url(Handle.t()) :: {:ok, String.t()} | {:error, :unsupported | error()}
  def public_url(%Handle{} = handle), do: adapter(handle).public_url(handle)

  @doc "Explicitly park a sandbox."
  @spec suspend(Handle.t()) :: :ok | {:error, error()}
  def suspend(%Handle{} = handle), do: adapter(handle).suspend(handle)

  @doc "Wake a parked sandbox."
  @spec resume(Handle.t()) :: {:ok, Handle.t()} | {:error, error()}
  def resume(%Handle{} = handle), do: adapter(handle).resume(handle)

  @doc "Write a file into the sandbox."
  @spec write_file(Handle.t(), String.t(), iodata(), keyword()) :: :ok | {:error, error()}
  def write_file(%Handle{} = handle, path, data, opts \\ []) do
    adapter(handle).write_file(handle, path, data, opts)
  end

  @doc "Run a command to completion."
  @spec exec(Handle.t(), String.t(), [String.t()], keyword()) ::
          {:ok, binary(), integer()} | {:error, error()}
  def exec(%Handle{} = handle, cmd, args, opts \\ []) do
    adapter(handle).exec(handle, cmd, args, opts)
  end

  @doc "Start a streaming command."
  @spec spawn(Handle.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Command.t()} | {:error, error()}
  def spawn(%Handle{} = handle, cmd, args, opts \\ []) do
    adapter(handle).spawn(handle, cmd, args, opts)
  end

  @doc "Write to a running command's stdin. Total."
  @spec write_stdin(Command.t(), iodata()) :: :ok | {:error, error()}
  def write_stdin(%Command{} = command, data) do
    adapter_for(command.provider).write_stdin(command, data)
  end

  @doc "Send stdin EOF to a running command."
  @spec close_stdin(Command.t()) :: :ok | {:error, error()}
  def close_stdin(%Command{} = command) do
    adapter_for(command.provider).close_stdin(command)
  end

  @doc "Stop the local command handle. Total."
  @spec stop_command(Command.t()) :: :ok
  def stop_command(%Command{} = command) do
    adapter_for(command.provider).stop_command(command)
  end

  @doc "List a sandbox's detachable sessions."
  @spec list_sessions(Handle.t()) :: {:ok, [Session.t()]} | {:error, error()}
  def list_sessions(%Handle{} = handle), do: adapter(handle).list_sessions(handle)

  @doc "Re-join a detached session."
  @spec attach(Handle.t(), String.t(), keyword()) :: {:ok, Command.t()} | {:error, error()}
  def attach(%Handle{} = handle, session_id, opts \\ []) do
    adapter(handle).attach(handle, session_id, opts)
  end

  @doc "Apply an egress policy."
  @spec apply_network_policy(Handle.t(), NetworkPolicy.t()) :: :ok | {:error, error()}
  def apply_network_policy(%Handle{} = handle, %NetworkPolicy{} = policy) do
    adapter(handle).apply_network_policy(handle, policy)
  end

  @doc """
  Make `policy` the sandbox's egress policy, writing it only when the
  provider does not already report exactly that policy.

  A write is not free on every provider: a Sprites policy write resets the
  guest's open TCP flows when it takes effect, and two writes about a second
  apart left test sprites cutting 1–2.5 % of their flows for the 50 s they
  were watched (fountain#2964). Where an adapter can read the policy back
  (`c:network_policy_in_force?/2`), an unchanged one is left alone and this
  answers `{:ok, :unchanged}`; otherwise it writes, as
  `apply_network_policy/2`, and answers `{:ok, :written}`.

  A skip trusts the provider's report of its stored policy to be the policy
  it enforces (ADR 0019 §2).
  """
  @spec ensure_network_policy(Handle.t(), NetworkPolicy.t()) ::
          {:ok, :unchanged | :written} | {:error, error()}
  def ensure_network_policy(%Handle{} = handle, %NetworkPolicy{} = policy) do
    adapter = adapter(handle)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :network_policy_in_force?, 2) and
         adapter.network_policy_in_force?(handle, policy) do
      {:ok, :unchanged}
    else
      with :ok <- __MODULE__.apply_network_policy(handle, policy), do: {:ok, :written}
    end
  end

  @doc """
  Resolve an in-sandbox path to the path a process *inside* the sandbox
  sees for it.

  On every hosted provider a sandbox is a real Linux box whose paths are
  literal (`/home/sprite` is `/home/sprite`), so this is the identity. A
  self-hosted runner (ADR 0022) maps `/home/sprite` onto a directory on the
  user's machine, and a path an agent CLI validates *in band* — the ACP
  `cwd` — must be the real one. Adapters that need the translation export
  `host_path/2`; everything else gets the path back unchanged.
  """
  @spec host_path(Handle.t(), String.t()) :: String.t()
  def host_path(%Handle{} = handle, path) do
    mod = adapter(handle)

    if function_exported?(mod, :host_path, 2) do
      mod.host_path(handle, path)
    else
      path
    end
  end

  defp adapter(%Handle{provider: provider}), do: adapter_for(provider)
end
