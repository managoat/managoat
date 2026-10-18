defmodule Fountain.Conversations.SpriteEnvTest do
  use Fountain.DataCase, async: true

  alias Fountain.Broker
  alias Fountain.Conversations.Redaction
  alias Fountain.Conversations.RedactionCarry
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Environments.Environment
  alias Fountain.{Environments, Vaults}

  # A runtime module that reports what it was handed, so the test can see the
  # defaults land first and the credentials reach them.
  defmodule Runtime do
    def default_env(_agent, creds), do: [{"RUNTIME_KEY", creds[:key]}]
  end

  defmodule SilentRuntime do
    def default_env(_agent, _creds), do: nil
  end

  # Claude's shape: one of two credentials is exported and the other is not,
  # plus a path of its own that is no secret.
  defmodule PickyRuntime do
    def default_env(_agent, creds),
      do: [{"HOME", "/home/sprite/.picky"}, {"PICKED", creds[:selected]}]
  end

  # A runtime that exports the Gemini key under the alias an environment or
  # vault may store it as, rather than the broker's own `GEMINI_API_KEY`.
  defmodule AliasRuntime do
    def default_env(_agent, creds),
      do: [{"GOOGLE_GENERATIVE_AI_API_KEY", creds[:gemini_api_key]}]
  end

  describe "build/4" do
    test "is the pieces in their fixed order, brokered placeholders last" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      # An atom key sorts before a binary one in a small map, so PORT comes
      # out first; both are coerced to strings on the way.
      env = %Environment{env_vars: %{"PLAIN" => "p", PORT: 8080}}

      sprite_env =
        SpriteEnv.build(nil, env, %{"DECRYPTED" => "a-decrypted-value"},
          runtime_module: Runtime,
          env_credentials: %{key: "k"},
          callback_token: "tok",
          conversation_id: conv_id,
          sandbox_id: "sb-1",
          sandbox_url: "https://sb.example",
          brokered: [{"OPENAI_API_KEY", "placeholder"}]
        )

      base = Fountain.PublicUrl.base()

      assert sprite_env ==
               [
                 {"RUNTIME_KEY", "k"},
                 {"MANAGOAT_BASE_URL", base},
                 {"FOUNTAIN_BASE_URL", base},
                 {"MANAGOAT_TOKEN", "tok"},
                 {"FOUNTAIN_TOKEN", "tok"},
                 {"MANAGOAT_CONVERSATION_ID", conv_id},
                 {"FOUNTAIN_CONVERSATION_ID", conv_id},
                 {"MANAGOAT_SANDBOX_ID", "sb-1"},
                 {"FOUNTAIN_SANDBOX_ID", "sb-1"},
                 {"SANDBOX_URL", "https://sb.example"}
               ] ++
                 SpriteEnv.git_author_env() ++
                 [
                   {"PORT", "8080"},
                   {"PLAIN", "p"},
                   {"DECRYPTED", "a-decrypted-value"},
                   {"OPENAI_API_KEY", "placeholder"}
                 ]
    end

    # ADR 0082: only Managoat's own MANAGOAT_* variables get a FOUNTAIN_*
    # twin, never a tenant's variable that happens to share the prefix.
    test "a tenant's MANAGOAT_* variable gets no FOUNTAIN_* twin" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      env = %Environment{env_vars: %{"MANAGOAT_MINE" => "x"}}

      sprite_env =
        SpriteEnv.build(nil, env, %{},
          runtime_module: Runtime,
          env_credentials: %{key: "k"},
          callback_token: "tok",
          conversation_id: conv_id,
          sandbox_id: nil
        )

      assert {"MANAGOAT_MINE", "x"} in sprite_env
      refute List.keymember?(sprite_env, "FOUNTAIN_MINE", 0)
    end

    # #1674. The broker used to be appended whole, so `env_vars` naming a CA
    # bundle was written into `.env` and then overwritten one line later by the
    # broker's own value — the documented setting did nothing, and pointing
    # codex at a stable bundle was impossible from the outside.
    test "the broker's CA defaults yield to env_vars; its proxy variables do not" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      mine = "/home/sprite/.ca/ca-bundle.crt"
      proxy = "http://av_sess_1:c-1@broker.example:443"

      env = %Environment{
        env_vars: %{"SSL_CERT_FILE" => mine, "HTTPS_PROXY" => "http://elsewhere:3128"}
      }

      # The pairs `Egress.sandbox_env/1` hands over, without needing a
      # configured proxy to mint a session for.
      brokered = [{"HTTPS_PROXY", proxy}, {"NO_PROXY", "localhost"}] ++ Fountain.Broker.ca_env()

      sprite_env =
        SpriteEnv.build(nil, env, %{},
          runtime_module: SilentRuntime,
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil,
          brokered: brokered
        )

      # `.env` is written top to bottom and a shell keeps the last assignment.
      last = fn key -> sprite_env |> Enum.filter(&(elem(&1, 0) == key)) |> List.last() end

      assert last.("SSL_CERT_FILE") == {"SSL_CERT_FILE", mine}
      assert last.("HTTPS_PROXY") == List.keyfind(brokered, "HTTPS_PROXY", 0)

      # The defaults are still there for every conversation that names none.
      assert last.("REQUESTS_CA_BUNDLE") == List.keyfind(brokered, "REQUESTS_CA_BUNDLE", 0)
    end

    test "a runtime with no defaults, no environment, no token and no URL contributes nothing" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      sprite_env =
        SpriteEnv.build(nil, nil, %{},
          runtime_module: SilentRuntime,
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil
        )

      assert sprite_env ==
               [{"MANAGOAT_CONVERSATION_ID", conv_id}, {"FOUNTAIN_CONVERSATION_ID", conv_id}] ++
                 SpriteEnv.git_author_env()
    end

    test "registers the secrets for redaction before returning" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      SpriteEnv.build(nil, nil, %{"LONG" => "a-value-long-enough-to-redact", "SHORT" => "ab"},
        runtime_module: SilentRuntime,
        env_credentials: %{},
        callback_token: "a-callback-token-value",
        conversation_id: conv_id,
        sandbox_id: nil
      )

      registered = Redaction.lookup(conv_id)
      assert "a-value-long-enough-to-redact" in registered
      assert "a-callback-token-value" in registered
      refute "ab" in registered
    end

    # ADR 0019 takes a bound credential out of the secrets map and leaves a
    # placeholder, so it never reaches the sprite env this registry is built
    # from. That is exactly why it has to be registered explicitly: an upstream
    # that echoes the header back returns the credential as ordinary tool
    # output, and `log_events` stores what a sprite writes verbatim.
    test "registers a brokered credential that never enters the sprite" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      sprite_env =
        SpriteEnv.build(nil, nil, %{"BOUND_TOKEN" => "__bound_token_placeholder__"},
          runtime_module: SilentRuntime,
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil,
          broker_credentials: %{"BOUND_TOKEN" => "the-real-brokered-credential"}
        )

      assert {"BOUND_TOKEN", "__bound_token_placeholder__"} in sprite_env,
             "the sandbox still sees only the placeholder"

      refute Enum.any?(sprite_env, fn {_k, v} -> v == "the-real-brokered-credential" end),
             "the credential must not be put into the sprite env to get it redacted"

      assert "the-real-brokered-credential" in Redaction.lookup(conv_id)

      assert Redaction.redact(conv_id, "upstream echoed the-real-brokered-credential back") ==
               "upstream echoed [REDACTED] back"
    end

    # #2366: the registry is what `RedactionCarry` holds output against, so a
    # non-secret in it costs the live stream a chunk of latency for every
    # character that begins it, and prints ordinary text as `[REDACTED]`.
    # Registering the env whole put the conversation and sandbox UUIDs in it.
    test "registers the secrets, and none of Fountain's own identifiers" do
      conv_id = Ecto.UUID.generate()
      sandbox_id = Ecto.UUID.generate()
      sandbox_url = "https://sb-9d3f1a2b.example.com"
      on_exit(fn -> Redaction.delete(conv_id) end)

      env = %Environment{env_vars: %{"TENANT_PLAIN" => "a-plain-configuration-value"}}

      SpriteEnv.build(nil, env, %{"TENANT_SECRET" => "a-decrypted-tenant-secret"},
        runtime_module: PickyRuntime,
        env_credentials: %{selected: "the-selected-inference-credential"},
        callback_token: "a-callback-token-value",
        conversation_id: conv_id,
        sandbox_id: sandbox_id,
        sandbox_url: sandbox_url,
        broker_credentials: %{"BOUND" => "the-real-brokered-credential"}
      )

      registered = Redaction.lookup(conv_id)

      for secret <- [
            "the-selected-inference-credential",
            "a-callback-token-value",
            "a-decrypted-tenant-secret",
            "the-real-brokered-credential",
            # Config by intention, but nothing stops a token being pasted into
            # one, and a tenant's own variables are few.
            "a-plain-configuration-value"
          ] do
        assert secret in registered, "#{secret} must stay registered"
      end

      for identifier <- [
            conv_id,
            sandbox_id,
            sandbox_url,
            Fountain.PublicUrl.base(),
            "/home/sprite/.picky",
            "aod@local"
          ] do
        refute identifier in registered, "#{identifier} is not a secret"
      end

      # The CA defaults are paths to a trust store, and a `/`-ending chunk
      # would be held against them.
      for {_key, path} <- Fountain.Broker.ca_env(), do: refute(path in registered)

      # A conversation that prints its own id reads it back (#2366).
      assert Redaction.redact(conv_id, "conversation #{conv_id}") == "conversation #{conv_id}"
    end

    # The whole point of the registry is still the secrets, so the credential
    # the runtime exported has to be in it — and the kind it passed over has
    # to not be, as `ConversationServerAcpTest` asserts of a subscription a
    # provider refused.
    test "registers the credential the runtime exported, and not the one it passed over" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      SpriteEnv.build(nil, nil, %{},
        runtime_module: PickyRuntime,
        env_credentials: %{selected: "the-exported-credential", other: "the-unused-credential"},
        callback_token: nil,
        conversation_id: conv_id,
        sandbox_id: nil
      )

      registered = Redaction.lookup(conv_id)
      assert "the-exported-credential" in registered
      refute "the-unused-credential" in registered
    end

    # ADR 0097: the variable that points the runtime at the conversation's
    # config home is in the process env, right after the runtime's defaults,
    # is no secret, and stays off the machine-wide env file; a tenant's own
    # value for the same variable still reaches both.
    test "points the runtime at the config home, unregistered and off the disk" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)
      home = "/home/sprite/.managoat/c/#{conv_id}"

      env =
        SpriteEnv.build(nil, nil, %{},
          runtime_module: Managoat.Runtimes.Claude,
          config_home: home,
          env_credentials: %{anthropic_api_key: "sk-ant-the-real-key"},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil
        )

      assert [
               {"ANTHROPIC_API_KEY", _},
               {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"},
               {"CLAUDE_CONFIG_DIR", ^home} | _
             ] = env

      refute home in Redaction.lookup(conv_id)

      disk = Fountain.Conversations.Identity.disk_env(env)
      refute List.keymember?(disk, "CLAUDE_CONFIG_DIR", 0)

      # The acp runtime's skills directory is the conversation's too, under
      # both of its names.
      acp =
        SpriteEnv.build(nil, nil, %{},
          runtime_module: Fountain.CommandRuntime,
          config_home: home,
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil
        )

      assert {"MANAGOAT_SKILLS_DIR", home <> "/skills"} in acp
      assert {"FOUNTAIN_SKILLS_DIR", home <> "/skills"} in acp

      assert Fountain.Conversations.Identity.disk_env(acp)
             |> List.keyfind("MANAGOAT_SKILLS_DIR", 0) == nil

      # A legacy home is the runtime's default directory: harmless on disk.
      legacy =
        SpriteEnv.build(nil, nil, %{},
          runtime_module: Managoat.Runtimes.Codex,
          config_home: "/home/sprite/.codex",
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil
        )

      assert {"CODEX_HOME", "/home/sprite/.codex"} in legacy
    end

    # `Broker.proxy_env/1` puts the session token in a URL's userinfo. The URL
    # is not a secret — its host is on the `broker` stage event — and holding
    # every chunk that ends in `h` against it is the #2366 cost in miniature.
    test "registers the broker session token, and not the URL that carries it" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      token = "av_sess_a-broker-session-token"
      proxy = "http://#{token}:vault-label@broker.example:443"

      SpriteEnv.build(nil, nil, %{},
        runtime_module: SilentRuntime,
        env_credentials: %{},
        callback_token: nil,
        conversation_id: conv_id,
        sandbox_id: nil,
        brokered: [{"HTTPS_PROXY", proxy}, {"NO_PROXY", "localhost,127.0.0.1"}]
      )

      registered = Redaction.lookup(conv_id)
      assert token in registered
      refute proxy in registered
      refute "vault-label" in registered

      # An agent printing its environment still hands over nothing.
      assert Redaction.redact(conv_id, "HTTPS_PROXY=#{proxy}") ==
               "HTTPS_PROXY=http://[REDACTED]:vault-label@broker.example:443"
    end

    # The cost #2366 measures, end to end: `RedactionCarry` holds a chunk back
    # when its end could begin a registered value, so a registered UUID delayed
    # a share of every reply — one hex character in sixteen, on a stream cut
    # wherever the model put its chunks.
    test "an ordinary chunk ending in any hex character is written at once" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      SpriteEnv.build(nil, nil, %{"TENANT_SECRET" => "SECRET-tenant-value"},
        runtime_module: SilentRuntime,
        env_credentials: %{},
        # Both registered values begin with a character the chunks below do
        # not end in, so only the registry's contents decide the result.
        callback_token: "tok-a-callback-token-value",
        conversation_id: conv_id,
        sandbox_id: Ecto.UUID.generate(),
        sandbox_url: "https://sb-#{Ecto.UUID.generate()}.example.com"
      )

      for <<char <- "0123456789abcdef">> do
        chunk = "model reply #{<<char>>}"

        assert {[{"stdout", ^chunk}], carry} =
                 RedactionCarry.feed(RedactionCarry.new(), conv_id, "stdout", chunk),
               "a chunk ending in #{<<char>>} waited for the next one"

        assert RedactionCarry.empty?(carry)
      end

      # A secret's first byte still holds, which is what the hold is for.
      assert {[], carry} =
               RedactionCarry.feed(RedactionCarry.new(), conv_id, "stdout", "here it comes: S")

      assert RedactionCarry.flush(carry, conv_id) == [{"stdout", "here it comes: S"}]
    end

    # Through `Broker.split/2` itself, not a hand-written placeholder: a
    # brokered key reaches `build/4` as `__github_token__`, which is generated
    # from the key and is no secret. Registering it held back every chunk of
    # output ending in `_` and printed the agent's own placeholder — the one
    # string it is meant to use — as `[REDACTED]` (#2366).
    test "a brokered secret registers the credential, and not the placeholder standing in for it" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      # `GITHUB_TOKEN` is a catalog key, so it brokers with no binding.
      {sandbox_secrets, brokered} = Broker.split(%{"GITHUB_TOKEN" => "ghp_the_real_credential"})
      placeholder = Broker.placeholder("GITHUB_TOKEN")
      assert sandbox_secrets == %{"GITHUB_TOKEN" => placeholder}

      sprite_env =
        SpriteEnv.build(nil, nil, sandbox_secrets,
          runtime_module: SilentRuntime,
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil,
          broker_credentials: brokered
        )

      assert {"GITHUB_TOKEN", placeholder} in sprite_env
      registered = Redaction.lookup(conv_id)
      assert "ghp_the_real_credential" in registered
      refute placeholder in registered

      # The agent may print the placeholder; it is what it was given to use.
      assert Redaction.redact(conv_id, "GITHUB_TOKEN=#{placeholder}") ==
               "GITHUB_TOKEN=#{placeholder}"

      assert Redaction.redact(conv_id, "upstream echoed ghp_the_real_credential") ==
               "upstream echoed [REDACTED]"

      # And a chunk ending where the placeholder begins is not held back.
      assert {[{"stdout", "ordinary_code_"}], carry} =
               RedactionCarry.feed(RedactionCarry.new(), conv_id, "stdout", "ordinary_code_")

      assert RedactionCarry.empty?(carry)
    end

    # Review of #2396: a placeholder is recognised by the broker's own account
    # of what it replaced, never by the shape of the value. A tenant may store
    # `__password__` as a password, and unbrokered it is a secret like any
    # other — dropping it would put it in `log_events` in plaintext.
    test "an unbrokered secret that looks like a placeholder is still a secret" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      # No binding and not a catalog key: the split leaves it alone and
      # brokers nothing.
      {sandbox_secrets, brokered} = Broker.split(%{"PASSWORD" => Broker.placeholder("PASSWORD")})
      assert sandbox_secrets == %{"PASSWORD" => "__password__"}
      assert brokered == %{}

      SpriteEnv.build(nil, nil, sandbox_secrets,
        runtime_module: SilentRuntime,
        env_credentials: %{},
        callback_token: nil,
        conversation_id: conv_id,
        sandbox_id: nil,
        broker_credentials: brokered
      )

      assert "__password__" in Redaction.lookup(conv_id)
      assert Redaction.redact(conv_id, "PASSWORD=__password__") == "PASSWORD=[REDACTED]"
    end

    # Review of #2396: the broker keys its map by its own name for a
    # credential, and a runtime may export that credential under another.
    # A Google key exported as `GOOGLE_GENERATIVE_AI_API_KEY` is held by the
    # broker as `GEMINI_API_KEY`, so the placeholder in the env is
    # `AIza__gemini_api_key__` and matching on the exported name missed it.
    test "a brokered credential exported under a runtime's own alias is still a placeholder" do
      conv_id = Ecto.UUID.generate()
      on_exit(fn -> Redaction.delete(conv_id) end)

      {env_credentials, brokered, _implicit} =
        Broker.split_inference(%{gemini_api_key: "AIzaSy_the_real_gemini_secret"})

      placeholder = Broker.placeholder("GEMINI_API_KEY")
      assert env_credentials == %{gemini_api_key: placeholder}
      assert brokered == %{"GEMINI_API_KEY" => "AIzaSy_the_real_gemini_secret"}

      sprite_env =
        SpriteEnv.build(%{model: "google/gemini-2.5-pro"}, nil, %{},
          runtime_module: AliasRuntime,
          env_credentials: env_credentials,
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil,
          broker_credentials: brokered
        )

      # The alias is what the runtime reads, and it carries the broker's key.
      assert {"GOOGLE_GENERATIVE_AI_API_KEY", placeholder} in sprite_env

      registered = Redaction.lookup(conv_id)
      assert "AIzaSy_the_real_gemini_secret" in registered
      refute placeholder in registered

      assert Redaction.redact(conv_id, "GOOGLE_GENERATIVE_AI_API_KEY=#{placeholder}") ==
               "GOOGLE_GENERATIVE_AI_API_KEY=#{placeholder}"

      # `AIza__` begins the placeholder and no registered value, so the chunk
      # goes out as it arrived. A chunk ending where the real key begins is
      # still held.
      chunk = "public placeholder AIza__"

      assert {[{"stdout", ^chunk}], carry} =
               RedactionCarry.feed(RedactionCarry.new(), conv_id, "stdout", chunk)

      assert RedactionCarry.empty?(carry)
      assert {[], _held} = RedactionCarry.feed(RedactionCarry.new(), conv_id, "stdout", "key: A")
    end

    test "a run with no broker registers exactly what it did before" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      SpriteEnv.build(nil, nil, %{"LONG" => "a-value-long-enough-to-redact"},
        runtime_module: SilentRuntime,
        env_credentials: %{},
        callback_token: nil,
        conversation_id: conv_id,
        sandbox_id: nil
      )

      assert "a-value-long-enough-to-redact" in Redaction.lookup(conv_id)
    end
  end

  describe "merge_secrets/3" do
    test "the vault wins over the environment on a key collision" do
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      env = insert_env(user_id: user.id)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "SHARED", "value" => "from-env"}, dek)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "ONLY_ENV", "value" => "e"}, dek)

      vault = insert_vault(user_id: user.id)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "SHARED", "value" => "from-vault"}, dek)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "ONLY_VAULT", "value" => "v"}, dek)

      assert SpriteEnv.merge_secrets(env, vault, dek) ==
               %{"SHARED" => "from-vault", "ONLY_ENV" => "e", "ONLY_VAULT" => "v"}

      assert SpriteEnv.merge_secrets(env, nil, dek) == %{
               "SHARED" => "from-env",
               "ONLY_ENV" => "e"
             }

      assert SpriteEnv.merge_secrets(nil, vault, dek) == %{
               "SHARED" => "from-vault",
               "ONLY_VAULT" => "v"
             }

      assert SpriteEnv.merge_secrets(nil, nil, dek) == %{}
    end
  end

  describe "the small pairs" do
    test "are empty for nil" do
      assert SpriteEnv.conversation_env(nil) == []
      assert SpriteEnv.sandbox_id_env(nil) == []
      assert SpriteEnv.sandbox_url_env(nil) == []
    end

    test "the otel pair is absent without a trace context" do
      # The pair is `TRACEPARENT` from `Fountain.Telemetry.current_traceparent/0`
      # when there is one. The test config installs no text-map propagator,
      # so no context can be injected here and only the absent half is
      # pinned; the present half is four lines that moved verbatim.
      assert SpriteEnv.otel_propagation_env() == []
    end
  end
end
