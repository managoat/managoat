defmodule Fountain.Conversations.CodexChatGPT do
  @moduledoc """
  How a ChatGPT subscription reaches a codex sandbox (ADR 0070).

  The resolver hands the runtime `:codex_chatgpt_access_token`, and on a
  brokered conversation `Egress.split_inference/3` replaces it with the
  placeholder of `CODEX_CHATGPT_ACCESS_TOKEN` and gives the broker the token,
  with a substitute rule on `chatgpt.com`. From there:

    * `env/2` exports `CODEX_CHATGPT_ACCESS_TOKEN` (the placeholder) to the
      codex process. Nothing reads its value; its presence is what
      `CodexTransport` selects the ChatGPT provider on.
    * `prepare_sandbox/5` writes `$CODEX_HOME/auth.json` in `chatgptAuthTokens`
      mode ("externally managed tokens": codex never refreshes them and never
      checks `exp`), with the placeholder where the bearer goes, the real
      account id, and an `id_token` synthesised from the stored claims. It
      replaces the library's API-key write for such a spawn. Codex sends the
      placeholder as its bearer, and the broker swaps in the token.
    * `peer_auth/2` is `:none`: codex-acp's api-key `authenticate` method
      would rewrite that file from an `OPENAI_API_KEY` the spawn does not
      have, and fail (measured 2026-09-08, ADR 0047 G0).

  The file names a placeholder, so it is worthless off the box. It is in the
  conversation's own config home (`CODEX_HOME`, ADR 0097), so no other
  conversation's codex reads it.
  """

  alias Fountain.ChatGPT
  alias Fountain.InferenceCredentials.Source

  @env_key "CODEX_CHATGPT_ACCESS_TOKEN"
  @credential :codex_chatgpt_access_token

  @doc "The env var the placeholder travels under."
  def env_key, do: @env_key

  @doc "The spawn env entry for a codex run on a subscription; nothing otherwise."
  @spec env(module() | nil, map()) :: [{String.t(), String.t()}]
  def env(Managoat.Runtimes.Codex, credentials) when is_map(credentials) do
    case Map.get(credentials, @credential) do
      value when is_binary(value) and value != "" -> [{@env_key, value}]
      _ -> []
    end
  end

  def env(_runtime_module, _credentials), do: []

  @doc """
  The `authenticate` method the ACP peer may use: `:none` on a subscription,
  the peer's default otherwise.
  """
  @spec peer_auth(module() | nil, map() | nil) :: :none | :api_key
  def peer_auth(runtime_module, credentials) do
    if env(runtime_module, credentials || %{}) == [], do: :api_key, else: :none
  end

  @doc """
  Write the `auth.json` for a codex spawn on a subscription under `home`,
  the conversation's config home. `:skip` for every other spawn, which then
  takes the library's `prepare_sandbox/4`. `{:error, :chatgpt_reconnect_required}` when the
  subscription the source names no longer serves.
  """
  @spec prepare_sandbox(
          Managoat.Sandbox.Handle.t(),
          String.t(),
          Source.t() | nil,
          term(),
          String.t()
        ) ::
          :skip | :ok | {:error, term()}
  def prepare_sandbox(handle, "codex", %Source{} = source, user_id, home) do
    case Source.chatgpt_owner(source) do
      nil ->
        :skip

      {^user_id, account_id} ->
        with {:ok, auth} <- ChatGPT.sandbox_auth(user_id, account_id) do
          body = auth_json(Fountain.Broker.placeholder(@env_key), auth)

          case Managoat.Sandbox.write_file(
                 handle,
                 Managoat.Runtimes.Codex.auth_path(home),
                 body,
                 mode: 0o600
               ) do
            :ok -> :ok
            {:error, reason} -> {:error, {:codex_auth_write, reason}}
          end
        end

      # The source came from this conversation's own resolution; this only
      # refuses a subscription that is not the conversation owner's.
      {_other, _account_id} ->
        {:error, :chatgpt_reconnect_required}
    end
  end

  def prepare_sandbox(_handle, _runtime, _source, _user_id, _home), do: :skip

  @doc "The `auth.json` body: `chatgptAuthTokens`, the bearer value, the account id, the synthesised id_token."
  @spec auth_json(String.t(), %{account_id: String.t(), id_token: String.t()}) :: String.t()
  def auth_json(access_value, %{account_id: account_id, id_token: id_token}) do
    Jason.encode!(%{
      "auth_mode" => "chatgptAuthTokens",
      "tokens" => %{
        "id_token" => id_token,
        "access_token" => access_value,
        "refresh_token" => "",
        "account_id" => account_id
      },
      "last_refresh" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end
end
