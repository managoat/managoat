defmodule Fountain.Broker.Native.InsightsTest do
  @moduledoc """
  The admin overview of the broker: counts, splits and lists derived from
  `broker_requests` and `broker_sessions`, every one bounded by the window.
  Rows are written straight into the log table here, the way the
  `RequestLog` writer does, so the shape under test is the table's.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Broker.Native.{Insights, Request, Sessions}

  defp log!(user, conv, attrs) do
    base = %{
      conversation_id: conv.id,
      user_id: user.id,
      method: "GET",
      host: "api.example.com",
      path: "/v1/things",
      outcome: "passthrough",
      credential_keys: [],
      inserted_at: DateTime.utc_now()
    }

    Repo.insert!(struct!(Request, Map.merge(base, Map.new(attrs))))
  end

  defp ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    %{user: user, conv: conv}
  end

  test "an empty log reads as zeros, not nils", %{} do
    overview = Insights._unsafe_overview_admin(24)

    assert overview.window == %{
             requests: 0,
             conversations: 0,
             tenants: 0,
             injected: 0,
             passthrough: 0,
             denied: 0,
             no_credential: 0,
             failed: 0
           }

    assert overview.sessions == %{live: 0, expired: 0, conversations: 0}
    assert overview.hosts == []
    assert overview.services == []
    assert overview.denied == []
    assert overview.failed == []
    assert overview.errors == []
    assert overview.live_sessions == []
    assert overview.cut_sandboxes == []
    assert overview.window_hours == 24
    assert is_integer(overview.retention_hours)
  end

  test "the window splits requests by outcome and counts who produced them", %{
    user: user,
    conv: conv
  } do
    other = insert_verified_user()
    other_conv = insert_conversation(user_id: other.id, agent: insert_agent(user_id: other.id))

    log!(user, conv, outcome: "injected", service: "github", credential_keys: ["GITHUB_TOKEN"])
    log!(user, conv, outcome: "injected", service: "github", credential_keys: ["GITHUB_TOKEN"])
    log!(user, conv, outcome: "passthrough", host: "registry.npmjs.org")
    log!(other, other_conv, outcome: "denied", host: "evil.example")
    log!(other, other_conv, outcome: "passthrough", error: "client_closed")
    # Outside the window: counted by nothing below.
    log!(user, conv, outcome: "denied", inserted_at: ago(30))

    overview = Insights._unsafe_overview_admin(24)

    assert overview.window == %{
             requests: 5,
             conversations: 2,
             tenants: 2,
             injected: 2,
             passthrough: 2,
             denied: 1,
             no_credential: 0,
             failed: 1
           }

    assert [%{host: "api.example.com", requests: 3, injected: 2, denied: 0, failed: 1} | rest] =
             overview.hosts

    assert Enum.map(rest, & &1.host) |> Enum.sort() == ["evil.example", "registry.npmjs.org"]

    assert [
             %{
               service: "github",
               requests: 2,
               conversations: 1,
               credential_keys: ["GITHUB_TOKEN"]
             }
           ] =
             overview.services

    assert [%{host: "evil.example", email: email, conversation_id: denied_conv}] = overview.denied
    assert email == other.email
    assert denied_conv == other_conv.id

    assert [%{error: "client_closed", email: _}] = overview.failed
    assert overview.errors == [%{error: "client_closed", requests: 1}]
  end

  test "a wider window reaches older rows, and an unknown one falls back to a day", %{
    user: user,
    conv: conv
  } do
    log!(user, conv, outcome: "denied", inserted_at: ago(30))

    assert Insights._unsafe_overview_admin(168).window.denied == 1
    assert Insights._unsafe_overview_admin(24).window.denied == 0
    assert Insights._unsafe_overview_admin(1).window.denied == 0
    assert Insights._unsafe_overview_admin(999).window_hours == 24
  end

  test "the binding table merges the variable names a rule attached across rows", %{
    user: user,
    conv: conv
  } do
    log!(user, conv, outcome: "injected", service: "gh", credential_keys: ["GITHUB_TOKEN"])

    log!(user, conv,
      outcome: "injected",
      service: "gh",
      credential_keys: ["GH_TOKEN", "GITHUB_TOKEN"]
    )

    # A matched passthrough rule is not a credential and does not count here.
    log!(user, conv, outcome: "passthrough", service: nil, credential_keys: [])

    assert [%{service: "gh", requests: 2, credential_keys: ["GH_TOKEN", "GITHUB_TOKEN"]}] =
             Insights._unsafe_overview_admin(24).services
  end

  test "live sessions list who holds a token, what it brokers, and skip expired ones", %{
    user: user,
    conv: conv
  } do
    {:ok, _} =
      Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        rules: [],
        unmatched_host_policy: :deny,
        meta: %{
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "credential_keys" => %{"github" => ["GITHUB_TOKEN"], "openai" => ["OPENAI_API_KEY"]}
        },
        ttl_seconds: 600
      })

    # Already over: the reaper has not run, so it is on disk and counted as such.
    {:ok, _} =
      Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        rules: [],
        meta: %{},
        ttl_seconds: 1
      })

    Repo.update_all(
      from(s in Fountain.Broker.Native.Session, where: s.unmatched_host_policy == "passthrough"),
      set: [expires_at: ago(1)]
    )

    overview = Insights._unsafe_overview_admin(24)

    assert overview.sessions == %{live: 1, expired: 1, conversations: 1}

    assert [session] = overview.live_sessions
    assert session.conversation_id == conv.id
    assert session.email == user.email
    assert session.policy == "deny"
    assert session.credential_keys == ["GITHUB_TOKEN", "OPENAI_API_KEY"]
    refute Map.has_key?(session, :rules_ciphertext)
    refute Map.has_key?(session, :token_hash)
  end

  # `managoat_broker` refuses a request whose credential it cannot supply with
  # a 502 that carries BOTH `outcome: denied` and `error: credential_missing`
  # (its `refusal_error/1`; every other refusal writes no error). Counting
  # `error IS NOT NULL` put that one request in Denied and in Failed at once,
  # in the tiles, in both tables and in both `top_hosts` columns.
  test "a refusal the broker made is counted once, under denied", %{user: user, conv: conv} do
    log!(user, conv,
      outcome: "denied",
      error: "credential_missing",
      status: 502,
      host: "api.github.com"
    )

    # Policy refusals write no error at all.
    log!(user, conv, outcome: "denied", status: 403, host: "api.github.com")
    # A forward that broke: this is what Failed means.
    log!(user, conv, outcome: "passthrough", error: "client_closed", host: "api.github.com")

    overview = Insights._unsafe_overview_admin(24)

    assert overview.window.denied == 2
    assert overview.window.no_credential == 1
    assert overview.window.failed == 1

    assert overview.window.injected + overview.window.passthrough + overview.window.denied ==
             overview.window.requests

    assert [%{host: "api.github.com", requests: 3, denied: 2, failed: 1}] = overview.hosts

    assert Enum.map(overview.denied, & &1.error) |> Enum.sort() == [nil, "credential_missing"]
    assert Enum.map(overview.failed, & &1.error) == ["client_closed"]
    assert overview.errors == [%{error: "client_closed", requests: 1}]
  end

  # `desc: r.id` and `desc: r.inserted_at` read the same and plan differently:
  # only the second can stop at the window's edge, which is the whole reason
  # the log table has an `inserted_at` index.
  test "the two action lists are newest first", %{user: user, conv: conv} do
    for minutes <- [30, 10, 20] do
      at = DateTime.add(DateTime.utc_now(), -minutes, :minute)
      log!(user, conv, outcome: "denied", host: "denied-#{minutes}.example", inserted_at: at)

      log!(user, conv,
        error: "upstream_reset",
        host: "failed-#{minutes}.example",
        inserted_at: at
      )
    end

    overview = Insights._unsafe_overview_admin(24)

    assert Enum.map(overview.denied, & &1.host) ==
             ["denied-10.example", "denied-20.example", "denied-30.example"]

    assert Enum.map(overview.failed, & &1.host) ==
             ["failed-10.example", "failed-20.example", "failed-30.example"]
  end

  # `Sessions.create/1` releases nothing but expired rows, so a conversation
  # holds one per provision and reattach. Oldest-first showed the stalest
  # duplicates and hid the token the sandbox is actually dialling with.
  test "live sessions are the most recently minted", %{user: user, conv: conv} do
    for _ <- 1..3 do
      {:ok, _} =
        Sessions.create(%{
          conversation_id: conv.id,
          user_id: user.id,
          rules: [],
          meta: %{},
          ttl_seconds: 600
        })
    end

    [oldest, middle, _newest] =
      Repo.all(from(s in Fountain.Broker.Native.Session, order_by: [asc: s.inserted_at]))

    # The stale duplicates outlive the current one, so soonest-to-expire is
    # exactly the wrong order to truncate on.
    Repo.update_all(from(s in Fountain.Broker.Native.Session, where: s.id == ^oldest.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), 30, :second)]
    )

    Repo.update_all(from(s in Fountain.Broker.Native.Session, where: s.id == ^middle.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), 60, :second)]
    )

    overview = Insights._unsafe_overview_admin(24)

    assert overview.sessions.live == 3
    assert overview.sessions.conversations == 1

    assert Enum.map(overview.live_sessions, & &1.id) ==
             Repo.all(from(s in Fountain.Broker.Native.Session, order_by: [desc: s.inserted_at]))
             |> Enum.map(& &1.id)
  end

  # The variable names come from a second read, because `array_agg` of arrays
  # of different lengths does not work. That read used to span the window and
  # have all but the ten displayed bindings thrown away on the next line.
  test "the variable-name read names the bindings it is for", %{user: user, conv: conv} do
    log!(user, conv, outcome: "injected", service: "gh", credential_keys: ["GITHUB_TOKEN"])

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:fountain, :repo, :query],
      # `:telemetry` handlers are global, so this fires for every query every
      # concurrent async test runs. Only this process's are ours.
      fn _, _, meta, _ ->
        if self() == test_pid and String.contains?(meta.query, "unnest") do
          send(test_pid, {:keys_query, meta.query})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert [%{service: "gh", credential_keys: ["GITHUB_TOKEN"]}] =
             Insights._unsafe_overview_admin(24).services

    assert_received {:keys_query, query}
    assert query =~ ~r/service.* = ANY\(/
  end

  test "a deleted tenant's rows go with the tenant", %{user: user, conv: conv} do
    log!(user, conv, outcome: "denied")
    # broker_requests.user_id cascades: the log is tenant data and leaves
    # with the account, so the page never has a row it cannot attribute.
    Repo.delete!(user)

    assert Insights._unsafe_overview_admin(24).denied == []
    assert Insights._unsafe_overview_admin(24).window.requests == 0
  end

  # #2503: a Sprites machine that silently drops any connection idle for
  # about a second cuts every streamed reply that pauses, and the broker logs
  # each as `client_closed`. Healthy streams do that under 1% of the time.
  describe "sandboxes cutting streams" do
    defp streams!(user, conv, n, attrs) do
      for _ <- 1..n//1, do: log!(user, conv, Keyword.merge([latency_ms: 4_000], attrs))
    end

    defp cut(), do: Insights._unsafe_overview_admin(24).cut_sandboxes

    test "flags a sandbox whose streams mostly end client_closed", %{user: user, conv: conv} do
      # A second conversation on the same sandbox counts toward it.
      conv2 =
        insert_conversation(
          user_id: user.id,
          agent: insert_agent(user_id: user.id),
          sandbox: Fountain.Machines.Lease.get(conv.sandbox_id)
        )

      streams!(user, conv, 5, error: "client_closed")
      streams!(user, conv2, 2, error: "client_closed", outcome: "injected", service: "openai")
      streams!(user, conv, 3, status: 200)

      # A healthy sandbox alongside it is not listed.
      other_conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      streams!(user, other_conv, 20, status: 200)

      assert [row] = cut()
      assert row.sandbox_id == conv.sandbox_id
      assert row.user_id == user.id
      assert row.email == user.email
      assert row.streams == 10
      assert row.cut == 7
      assert row.conversations == 2
      assert_in_delta row.share, 0.7, 0.001
      assert row.provider == "sprites"
      assert is_binary(row.machine_name)
      assert %DateTime{} = row.last_seen_at
    end

    test "fewer than ten streams is not enough to flag", %{user: user, conv: conv} do
      streams!(user, conv, 9, error: "client_closed")
      assert cut() == []
    end

    test "a share under half is not flagged", %{user: user, conv: conv} do
      streams!(user, conv, 9, error: "client_closed")
      streams!(user, conv, 11, status: 200)
      assert cut() == []

      # Exactly half is.
      streams!(user, conv, 2, error: "client_closed")
      assert [%{streams: 22, cut: 11}] = cut()
    end

    test "short requests, refusals and other errors are not streams cut", %{
      user: user,
      conv: conv
    } do
      # Quick calls a cancelled turn hangs up on, or with no latency at all.
      streams!(user, conv, 20, error: "client_closed", latency_ms: 999)
      streams!(user, conv, 5, error: "client_closed", latency_ms: nil)
      # Refusals never forwarded.
      streams!(user, conv, 20, outcome: "denied", error: "credential_missing")
      assert cut() == []

      # Long streams that failed upstream are streams, but not cut ones.
      streams!(user, conv, 6, error: "upstream_closed")
      streams!(user, conv, 4, error: "client_closed")
      assert cut() == []
    end

    test "only rows inside the window count", %{user: user, conv: conv} do
      streams!(user, conv, 10, error: "client_closed", inserted_at: ago(30))
      assert cut() == []
      assert [%{cut: 10}] = Insights._unsafe_overview_admin(168).cut_sandboxes

      # Recent healthy streams outweigh day-old cuts in the wider window only.
      streams!(user, conv, 12, status: 200)
      assert Insights._unsafe_overview_admin(168).cut_sandboxes == []
    end
  end
end
