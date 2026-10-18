defmodule Fountain.Conversations.Identity do
  @moduledoc """
  Which conversation a process inside a sandbox belongs to — carried by the
  process, never by the disk.

  A sandbox row has been `has_many :conversations` since the first migration,
  and the team's fresh-conversation verb (#840, removed with the team in
  ADR 0074) produced a second conversation on one row in production. What stayed 1:1 was the
  identity: `FOUNTAIN_TOKEN` (the per-conversation callback key) and
  `FOUNTAIN_CONVERSATION_ID` were written to `/home/sprite/.env` — one path,
  rewritten on every provision and reattach — and a reattach after a deploy
  bound to the *head* of the sandbox's session list, because nothing on a
  session said whose it was. Two conversations mid-turn on one machine across
  a deploy would have streamed one agent into the other's transcript
  (ADR 0023, survey items 1 and 2).

  Three rules, all enforced here:

    * **Identity is process env.** `disk_env/1` strips the per-conversation
      pairs before the env file is written; the same pairs still reach every
      spawn through `env:`, so the agent's tools inherit them exactly as
      before. What a `source .env` in a setup script loses is the callback
      token and the inference credential, neither of which the file had any
      business holding — it is for environment and vault values, which are
      the same for every conversation on the machine. Both still reach the
      setup script itself: `Provisioning.run_setup_script/4` execs with
      `env: sprite_env`, the whole list.

    * **A session inherits its conversation.** `tag_command/3` wraps the spawn as
      `env MANAGOAT_CONVERSATION_ID=<id> FOUNTAIN_CONVERSATION_ID=<id> <cmd> <args…>`
      (both names until ADR 0082's window closes). The process gets the
      variable, and providers retaining the original command expose the tag
      in `Managoat.Sandbox.Session.command`. A runtime can replace that command
      while retaining the environment. No argv is added to the adapter itself.

    * **Reattach matches on identity.** Sprites reports the current process
      command, so `env` and its argv tag disappear after exec. `session_owners/2`
      recovers the inherited identity from that process's environment when
      needed. Unidentified processes are never candidates: the transitional
      untagged-head fallback could bind two owners to one process (#1658).
      Fountain owns routing; the ACP peer cannot recover misrouted bytes.
  """

  alias Managoat.Sandbox.{Handle, Session}

  @tag_key "MANAGOAT_CONVERSATION_ID"
  @legacy_tag_key "FOUNTAIN_CONVERSATION_ID"

  # Per-conversation pairs. `MANAGOAT_BASE_URL` stays on disk: it is the same
  # for every conversation and a setup script may legitimately read it.
  #
  # The broker proxy address carries the conversation's session token (ADR
  # 0019 §5), so it is per-conversation too: on disk it would be a
  # cross-conversation read of a credential that brokers another tenant's
  # vault. `Fountain.Broker.process_only_keys/0` names the variables.
  #
  # Inference auth inputs are per-conversation (ADR 0053 decision 4),
  # including tenant env/vault secrets with a supported name or alias.
  # Unbrokered values are bearer material; broker placeholders are harmless
  # fixed strings, but neither needs to persist in the shared env file.
  # Runtime-owned auth files require separate isolation (decision 6).
  # A ChatGPT subscription's placeholder (ADR 0070) is process env too.
  #
  # Each Managoat variable is also exported under its `FOUNTAIN_*` name until
  # the deprecation window ADR 0082 opened closes (`SpriteEnv.with_legacy_names/1`),
  # so the old names are per-conversation too.
  @process_only [@tag_key, @legacy_tag_key, "MANAGOAT_TOKEN", "FOUNTAIN_TOKEN"] ++
                  ["TRACEPARENT", "CODEX_CHATGPT_ACCESS_TOKEN"] ++
                  Fountain.Broker.process_only_keys() ++
                  (Fountain.InferenceCredentials.env_aliases() |> Map.values() |> List.flatten())

  # A session spawned by a release before ADR 0082 carries only the old name,
  # and one spawned by this release carries both, so a rollback still finds it.
  # E2B lists the journal wrapper, which shell-quotes each complete argv
  # element. Match paired quotes as well as bare assignments so a surviving
  # adapter remains identifiable on wake (#2865). Keep whole-token boundaries:
  # a prefix, suffix or unmatched quote must not establish ownership.
  @tag_re ~r/(?:^|\s)(['"]?)(?:MANAGOAT|FOUNTAIN)_CONVERSATION_ID=([0-9a-fA-F-]{36})\1(?:\s|$)/

  @doc "The env var that tags a session with its conversation."
  @spec tag_key() :: String.t()
  def tag_key, do: @tag_key

  @doc """
  The subset of a sprite env that belongs on the machine's disk: everything
  except the per-conversation identity and inference auth inputs.
  """
  @spec disk_env([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def disk_env(sprite_env) when is_list(sprite_env) do
    Enum.reject(sprite_env, fn {k, v} ->
      to_string(k) in @process_only or conversation_home_pair?(to_string(k), v)
    end)
  end

  # A conversation's config home (ADR 0097) is its own too: the variable that
  # points a runtime at it names one conversation's directory. Told apart by
  # its value rather than its name, because a tenant's own `CODEX_HOME` (say)
  # is machine-wide configuration and stays on the disk.
  @config_vars ~w(CLAUDE_CONFIG_DIR CODEX_HOME GEMINI_CLI_HOME MANAGOAT_SKILLS_DIR FOUNTAIN_SKILLS_DIR)

  defp conversation_home_pair?(key, value) when key in @config_vars and is_binary(value),
    do: String.starts_with?(value, Managoat.Runtimes.Layout.config_homes() <> "/")

  defp conversation_home_pair?(_key, _value), do: false

  @doc """
  Wrap a command so its session is tagged with `conv_id` and the process sees
  the variable under both its names:
  `{"env", ["MANAGOAT_CONVERSATION_ID=<id>", "FOUNTAIN_CONVERSATION_ID=<id>", cmd | args]}`.
  """
  @spec tag_command(String.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def tag_command(conv_id, cmd, args) when is_binary(conv_id) and is_binary(cmd) do
    {"env", ["#{@tag_key}=#{conv_id}", "#{@legacy_tag_key}=#{conv_id}", cmd | args]}
  end

  @doc """
  The conversation a session was spawned for, read from its command line, or
  `nil` when the tag is absent, including after the runtime replaces argv.
  """
  @spec conversation_id(Session.t()) :: String.t() | nil
  def conversation_id(%Session{command: command}) when is_binary(command) do
    case Regex.run(@tag_re, command, capture: :all_but_first) do
      [_quote, id] -> String.downcase(id)
      _ -> nil
    end
  end

  def conversation_id(%Session{}), do: nil

  # Sprites exec session ids are the process ids reported by its exec list.
  # Read only the identity, inside the sandbox: the rest of /proc/*/environ
  # contains credentials and must never cross the transport or reach logs.
  @process_identity_script """
  for pid do
    if [ -r "/proc/$pid/environ" ]; then
      tr '\\000' '\\n' < "/proc/$pid/environ" 2>/dev/null |
        sed -n -E "s/^(MANAGOAT|FOUNTAIN)_CONVERSATION_ID=/$pid /p"
    fi
  done
  """

  @doc """
  Verified session owners, keyed by provider session id. Command tags work on
  every provider. Sprites also exposes its exec process through `/proc/<id>`;
  its inherited env survives a runtime changing argv. Failed reads and absent
  or malformed identities leave the session unidentified, never a fallback.
  """
  @spec session_owners(Handle.t(), [Session.t()]) :: %{String.t() => String.t() | nil}
  def session_owners(handle, sessions) do
    tagged = Map.new(sessions, &{&1.id, conversation_id(&1)})
    Map.merge(tagged, process_identities(handle, tagged))
  end

  @doc """
  Resolve a reattach candidate, its identity source and the superseded sessions
  owned by the same conversation. One identity snapshot decides both selection
  and cleanup; unidentified sessions are never offered for either.
  """
  @spec reattach_session(Handle.t(), [Session.t()], String.t()) ::
          {:ok, Session.t(), String.t(), [Session.t()]} | :none
  def reattach_session(handle, sessions, conv_id) do
    owners = session_owners(handle, sessions)

    case pick_session(sessions, conv_id, owners) do
      {:tagged, session} ->
        source = if conversation_id(session), do: "tag", else: "process_env"

        superseded =
          Enum.filter(sessions, fn candidate ->
            candidate.id != session.id and owners[candidate.id] == String.downcase(conv_id)
          end)

        {:ok, session, source, superseded}

      :none ->
        :none
    end
  end

  @doc "All verified processes belonging to an owner, for idle-session cleanup."
  @spec owned_sessions(Handle.t(), [Session.t()], String.t()) :: [Session.t()]
  def owned_sessions(handle, sessions, conv_id) do
    owners = session_owners(handle, sessions)
    Enum.filter(sessions, &(owners[&1.id] == String.downcase(conv_id)))
  end

  defp process_identities(%Handle{provider: :sprites} = handle, tagged) do
    ids = for {id, nil} <- tagged, is_binary(id), Regex.match?(~r/^[0-9]+$/, id), do: id

    case ids do
      [] -> %{}
      _ -> read_process_identities(handle, ids)
    end
  end

  defp process_identities(_handle, _tagged), do: %{}

  defp read_process_identities(handle, ids) do
    args = ["-c", @process_identity_script, "fountain-session-identity" | ids]

    case Managoat.Sandbox.exec(handle, "sh", args, []) do
      {:ok, output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, owners ->
          case String.split(line, " ", parts: 2) do
            [id, owner] when byte_size(owner) == 36 ->
              case {id in ids, Ecto.UUID.cast(owner)} do
                {true, {:ok, uuid}} -> Map.put(owners, id, uuid)
                _ -> owners
              end

            _ ->
              owners
          end
        end)

      _ ->
        %{}
    end
  end

  @doc """
  The session a reattaching server for `conv_id` should bind to.
  Pass `session_owners/2` as `owners` to include recovered process identities.

    * `{:tagged, session}` — a session carrying this conversation's tag. The
      newest one if there are several (a peer that died mid-handshake can
      leave an older idle adapter behind; the caller already stops those).
    * `:none` — nothing to bind to. Sessions tagged with *another*
      conversation, or carrying no tag, are never offered.
  """
  @spec pick_session([Session.t()], String.t(), map()) ::
          {:tagged, Session.t()} | :none
  def pick_session(sessions, conv_id, owners \\ %{})
      when is_list(sessions) and is_binary(conv_id) do
    wanted = String.downcase(conv_id)

    case Enum.filter(sessions, fn s -> (owners[s.id] || conversation_id(s)) == wanted end) do
      [] -> :none
      ours -> {:tagged, newest(ours)}
    end
  end

  # Providers report `created_at`; where they do not, list order stands.
  defp newest(sessions) do
    if Enum.all?(sessions, &match?(%DateTime{}, &1.created_at)) do
      Enum.max_by(sessions, & &1.created_at, DateTime)
    else
      hd(sessions)
    end
  end
end
