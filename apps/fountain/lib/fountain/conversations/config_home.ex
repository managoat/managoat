defmodule Fountain.Conversations.ConfigHome do
  @moduledoc """
  A conversation's config home and working directory (ADR 0097, step 1).

  **The config home** is the directory the conversation's runtime keeps its
  configuration in: skills, the instructions file, MCP servers, its session
  store and its inference credential files. A conversation launched since
  ADR 0097 has one of its own, `/home/sprite/.managoat/c/<conversation_id>`,
  recorded on the row at launch (`config_home`) and fixed for its life. The
  runtime is pointed at it by one variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`
  or `GEMINI_CLI_HOME`, see `Managoat.Runtimes.Layout`), which the
  conversation's every process carries.

  **A conversation from before that** has no `config_home` on its row. Its
  runtime session and its skills are in the shared directory its runtime used
  then (`~/.claude`, `~/.codex`, and `/tmp` for gemini, whose `HOME` it was),
  so `home/1` answers that directory for it, and the same variable points the
  runtime there. There is one code path: every reader asks `home/1`, and the
  legacy directory is only the value a row with no recorded home gets. It is
  not moved on wake: a reattached adapter from the previous release may still
  be running in it, and the conversation's sandbox goes when it ends, so the
  legacy layout drains out with the conversations that have it.

  **The working directory** is the launch's `cwd`, or the runtime's default
  (`Fountain.RuntimeDispatch.cwd/1`) when it named none, which is also what a
  conversation from before the field runs in. `validate_cwd/2` is the rule a
  launch is held to; `ensure/2` creates both directories on the machine
  before the adapter is spawned there.

  **Ending a conversation** removes its config home (`remove/2`), best
  effort, after its adapter has stopped. In this step the sandbox is
  destroyed straight after, so the removal matters only once a machine can
  outlive one of its conversations (ADR 0097's later steps); a legacy home is
  shared and is never removed.
  """

  require Logger

  alias Fountain.Conversations.Conversation
  alias Managoat.Runtimes.Layout

  # Where a launch's `cwd` may point: the image's home for every runtime, and
  # gemini's own default tree as well (its default cwd is under /tmp).
  @image_home Layout.image_home()
  @gemini_roots ["/tmp"]
  @max_cwd 1024

  @doc "The config home a conversation launched now gets: its own, by id."
  @spec for_launch(String.t()) :: String.t()
  def for_launch(conversation_id), do: Layout.config_home(conversation_id)

  @doc """
  The conversation's config home: the one on its row, or for a row from
  before config homes, the shared directory its runtime used then.
  """
  @spec home(map()) :: String.t()
  def home(%{config_home: home}) when is_binary(home) and home != "", do: home
  def home(conv), do: legacy_home(runtime(conv))

  @doc """
  The shared directory `runtime` used as its config home before ADR 0097.
  The `acp` runtime borrowed claude's tree (`Fountain.CommandRuntime`).
  """
  @spec legacy_home(String.t() | nil) :: String.t()
  def legacy_home(runtime), do: Layout.legacy_home(runtime) || Layout.legacy_home("claude")

  @doc "The working directory the conversation's agent runs in."
  @spec cwd(map()) :: String.t()
  def cwd(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd
  def cwd(conv), do: Fountain.RuntimeDispatch.cwd(runtime(conv))

  @doc """
  The directories a launch's `cwd` may lie in (or be) for `runtime`:
  `/home/sprite` for every runtime, and `/tmp` too for gemini, whose default
  working directory is there.
  """
  @spec cwd_roots(String.t() | nil) :: [String.t()]
  def cwd_roots("gemini"), do: [@image_home | @gemini_roots]
  def cwd_roots(_runtime), do: [@image_home]

  @doc """
  Check a launch's `cwd` for `runtime` and normalise it.

  `nil` (or an empty string) asks for nothing: the runtime's default stands,
  and nil is what is recorded. Otherwise it must be an absolute path of at
  most #{@max_cwd} bytes with no control characters, under one of
  `cwd_roots/1` once `.` and `..` are resolved, and not inside the directory
  config homes live in. It is answered normalised (`/home/sprite/a/../b/`
  is `/home/sprite/b`). A refusal is a changeset error on `:cwd`, which the
  API renders as `422 validation_failed` naming the field.
  """
  @spec validate_cwd(term(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t()}
  def validate_cwd(cwd, _runtime) when cwd in [nil, ""], do: {:ok, nil}

  def validate_cwd(cwd, runtime) when is_binary(cwd) do
    roots = cwd_roots(runtime)

    cond do
      byte_size(cwd) > @max_cwd ->
        refuse("must be at most #{@max_cwd} bytes")

      not String.valid?(cwd) or String.match?(cwd, ~r/[\x00-\x1f\x7f]/) ->
        refuse("must not contain control characters")

      not String.starts_with?(cwd, "/") ->
        refuse("must be an absolute path")

      true ->
        normalized = Path.expand(cwd)

        cond do
          not Enum.any?(roots, &under?(normalized, &1)) ->
            refuse("must be #{Enum.join(roots, " or ")}, or a directory under it")

          under?(normalized, Path.dirname(Layout.config_homes())) ->
            refuse("must not be inside #{Path.dirname(Layout.config_homes())}")

          true ->
            {:ok, normalized}
        end
    end
  end

  def validate_cwd(_cwd, _runtime), do: refuse("must be a string")

  @doc """
  On a resume, a `cwd` the request names must be the one the conversation
  runs in: it is fixed for the conversation's life. nil asks for nothing.
  """
  @spec check_resume(Conversation.t(), term()) :: :ok | {:error, Ecto.Changeset.t()}
  def check_resume(_conv, cwd) when cwd in [nil, ""], do: :ok

  def check_resume(conv, cwd) do
    with {:ok, requested} <- validate_cwd(cwd, runtime(conv)) do
      if requested == cwd(conv),
        do: :ok,
        else: refuse("is fixed for the conversation's life; it runs in #{cwd(conv)}")
    end
  end

  @doc """
  Create the conversation's working directory, and its config home beside
  it, on the machine behind `handle` before its adapter is spawned there.
  Idempotent, so every provision, wake and reattach runs it.

  Only a launch that named its own `cwd` costs an exec. A runtime's default
  working directory is always there (`/home/sprite`, or gemini's, which its
  `prepare_sandbox/4` creates), and the config home is created by the first
  file written into it: the runtime's settings, its skills, its credential
  file.
  """
  @spec ensure(Managoat.Sandbox.Handle.t(), map()) :: :ok | {:error, term()}
  def ensure(handle, conv) do
    if Map.get(conv, :cwd) in [nil, ""], do: :ok, else: make_directories(handle, conv)
  end

  defp make_directories(handle, conv) do
    script = "mkdir -p -- #{quote_shell(home(conv))} #{quote_shell(cwd(conv))}"

    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.exec(handle, "bash", ["-c", script], timeout: 15_000) end,
           label: "conversation directories"
         ) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, code} -> {:error, {:conversation_directories, {:exit, code}}}
      {:error, reason} -> {:error, {:conversation_directories, reason}}
    end
  end

  @doc """
  Remove the conversation's config home from the machine behind `handle`,
  best effort: a failure is logged and answered `:ok`, because the
  conversation is ending either way. Only a conversation's own home is
  removed (`Managoat.Runtimes.Layout.conversation_home?/1`); a legacy home is
  shared with whatever else ran there and is left alone. Never logs a value
  from inside the directory.
  """
  @spec remove(Managoat.Sandbox.Handle.t() | nil, map()) :: :ok
  def remove(nil, _conv), do: :ok

  def remove(handle, conv) do
    home = home(conv)

    if Layout.conversation_home?(home) do
      case Managoat.Sandbox.exec(handle, "bash", ["-c", "rm -rf -- #{quote_shell(home)}"],
             timeout: 5_000
           ) do
        {:ok, _out, 0} ->
          :ok

        other ->
          Logger.info("conv #{conv.id}: config home not removed: #{inspect(outcome(other))}")
          :ok
      end
    else
      :ok
    end
  end

  defp outcome({:ok, _out, code}), do: {:exit, code}
  defp outcome({:error, reason}), do: reason

  defp refuse(message) do
    {:error,
     %Conversation{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:cwd, message)
     |> Map.put(:action, :insert)}
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # A conversation's runtime is validated-required and outlives its agent.
  defp runtime(%{runtime: runtime}) when is_binary(runtime), do: runtime
  defp runtime(_conv), do: "claude"

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
