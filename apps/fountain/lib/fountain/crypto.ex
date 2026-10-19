defmodule Fountain.Crypto do
  @moduledoc """
  Envelope encryption for per-account secret values at rest.

  Each account has a data-encryption key (DEK) stored wrapped (AES-256-GCM) in
  `user_data_keys.wrapped_key` using the platform master key (`MASTER_SECRETS_KEY`).

  `encrypt/3` and `decrypt/3` accept an explicit `key` argument — callers are
  responsible for supplying the correct account's DEK, which keeps one account's
  secrets unreadable with another's key.

  ## Key lifecycle

  1. At user creation: `generate_dek/0` → `wrap_dek/1` → store in `user_data_keys`
  2. At conversation start: `load_tenant_key/1` → unwrap DEK → hold in GenServer state
  3. On encrypt/decrypt: pass DEK as `key` argument to `encrypt/3` / `decrypt/3`
  4. On `ConversationServer.terminate/2`: discard the DEK (drop from state)

  ## Master key

  `MASTER_SECRETS_KEY` is a 32-byte binary, base64url-encoded, set at runtime.
  In dev/test a deterministic dev key is derived from a fixed phrase; it must
  be set in prod (`PHX_SERVER=true`). See `config/runtime.exs`.

  ## Migration seam

  `user_data_keys.algorithm` is `"aes_256_gcm_wrap"` at launch. When KMS is
  introduced, the column switches to `"kms"` and `kms_key_id` is populated.
  `load_tenant_key/1` will branch on `algorithm` at that point; today only
  `"aes_256_gcm_wrap"` is handled.
  """

  @aad "fountain.secret"
  @key_wrap_aad "fountain.key_wrap"

  @doc """
  Encrypt `plaintext` using AES-256-GCM with the given 32-byte `key`.

  Returns a binary: `iv(12) <> auth_tag(16) <> ciphertext`.
  Each call uses a fresh random IV, so the same plaintext produces different output.
  """
  @spec encrypt(binary(), binary(), binary()) :: binary()
  def encrypt(plaintext, key, aad \\ @aad)
      when is_binary(plaintext) and is_binary(key) and is_binary(aad) do
    validate_key!(key)
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)
    iv <> tag <> ciphertext
  end

  @doc """
  Decrypt a binary produced by `encrypt/3`.

  Returns `{:ok, plaintext}` or `:error` (wrong key, wrong aad, or corrupted data).
  """
  @spec decrypt(binary(), binary(), binary()) :: {:ok, binary()} | :error
  def decrypt(blob, key, aad \\ @aad)

  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, key, aad)
      when is_binary(key) and is_binary(aad) do
    validate_key!(key)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_, _, _), do: :error

  @doc """
  Generate a fresh random 32-byte data-encryption key (DEK).
  """
  @spec generate_dek() :: binary()
  def generate_dek, do: :crypto.strong_rand_bytes(32)

  @doc """
  Wrap (encrypt) a tenant DEK using the platform `MASTER_SECRETS_KEY`.

  The result is stored in `user_data_keys.wrapped_key`. It is 60 bytes:
  `iv(12) <> tag(16) <> dek(32)`.
  """
  @spec wrap_dek(binary()) :: binary()
  def wrap_dek(dek) when is_binary(dek) and byte_size(dek) == 32 do
    encrypt(dek, master_key(), @key_wrap_aad)
  end

  @doc """
  Load a tenant's DEK by unwrapping the value stored in `user_data_keys`.

  Returns `{:ok, dek}` (32-byte binary) or `{:error, reason}` where reason is:
  - `:not_found` — no `user_data_keys` row exists for this user
  - `:unwrap_failed` — master key mismatch or corrupted wrapped_key

  The caller (typically `ConversationServer.init/1`) should store the DEK in
  GenServer state and pass it to `encrypt/3` / `decrypt/3` for the conversation
  lifetime, then discard it on terminate.

  `opts` go to the read and are empty for every caller but one: the broker's
  per-request path (`Fountain.Broker.Native.Sessions.authorize/2`) passes a
  `:timeout`, because it runs for every egress request of a sandbox and must
  not wait on the database for longer than it says it does.
  """
  @spec load_tenant_key(binary(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def load_tenant_key(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    case Fountain.Repo.get_by(Fountain.Accounts.UserDataKey, [user_id: user_id], opts) do
      nil ->
        {:error, :not_found}

      %Fountain.Accounts.UserDataKey{wrapped_key: wrapped_key} ->
        case decrypt(wrapped_key, master_key(), @key_wrap_aad) do
          {:ok, <<_::binary-32>> = dek} -> {:ok, dek}
          {:ok, _} -> {:error, :unwrap_failed}
          :error -> {:error, :unwrap_failed}
        end
    end
  end

  @doc """
  A 32-byte key for one purpose, named by `info`: HKDF-SHA256 (RFC 5869,
  one block) over `MASTER_SECRETS_KEY` with a zero salt, as the broker CA's
  seed is derived (`Fountain.Broker.Native.ca_seed/0`). It is never the key
  that wraps a DEK, and a different `info` gives an unrelated key. Rotating
  the master key rotates it.
  """
  @spec derived_key(String.t()) :: <<_::256>>
  def derived_key(info) when is_binary(info) do
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, master_key())
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  # Private

  defp master_key do
    case Application.fetch_env!(:fountain, :master_secrets_key) do
      <<_::binary-32>> = k ->
        k

      other ->
        raise "expected :master_secrets_key to be 32 bytes, got #{byte_size(other)} bytes. " <>
                "Check MASTER_SECRETS_KEY env var."
    end
  end

  defp validate_key!(key) do
    unless byte_size(key) == 32 do
      raise ArgumentError,
            "encryption key must be exactly 32 bytes, got #{byte_size(key)}. " <>
              "Pass the tenant DEK from load_tenant_key/1."
    end
  end
end
