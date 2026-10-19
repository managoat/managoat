defmodule Fountain.ConversationServerCase do
  @moduledoc """
  Harness for driving a real `ConversationServer` in tests.

  The module has had no tests of its own since launch — 1,183 lines covering
  provisioning, reattach, turn handling and teardown, holding tenant secrets and
  spending money, excluded from the coverage gate and `Mimic.copy`'d out of
  every caller's tests. The reason it stayed untested is that starting one
  reaches for the Sprites API, the filesystem inside a sprite, a runtime CLI and
  OpenTelemetry.

  This stubs that boundary once, permissively, so an individual test only has to
  express the thing it cares about. `stub/3` is used rather than `expect/3` so
  unstated calls are allowed; tests that care about a specific interaction
  override it.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Fountain.DataCase, async: false
      use Mimic

      import Fountain.ConversationServerCase

      alias Fountain.Conversations
      alias Fountain.Conversations.ConversationServer

      # The server runs in its own process, so per-process stubs set from the
      # test would not apply to it. Global mode is safe here because these
      # modules are async: false, and ExUnit runs those one at a time after the
      # async ones have finished.
      setup :set_mimic_global

      # DataCase shares the connection through a separate owner that survives
      # until on_exit. Keep that owner while ExUnit stops supervised servers.
    end
  end

  @doc """
  Stub every external boundary a provision touches, on the happy path.

  The whole sandbox seam is the `Managoat.Sandbox.Sprites` adapter — the
  server never names the SDK anymore. Returns the handle the stubbed
  `create/2` will hand back.
  """
  def stub_happy_sprite(name \\ "test-sprite") do
    handle = Managoat.Sandbox.Sprites.build_handle(name)

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts -> {:ok, handle} end)
    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)

    Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :running, raw: %{}}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn
      # `Managoat.Runtimes.JsonConfig`'s read: every file absent, one line each.
      _handle, "bash", ["-c", _script, "managoat-json-read" | paths], _opts ->
        {:ok, String.duplicate("-\n", length(paths)), 0}

      _handle, _cmd, _args, _opts ->
        {:ok, "", 0}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _handle, _path, _data, _opts -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _handle -> {:ok, []} end)
    Mimic.stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _handle, _policy -> :ok end)
    # An attach reads the floor back first; nothing is in force unless a test says so.
    Mimic.stub(Managoat.Sandbox.Sprites, :network_policy_in_force?, fn _handle, _policy ->
      false
    end)

    # No pushed adapter bundle unless a test asks for one: the adapter then
    # installs after the floor, the path most tests here are about.
    Mimic.stub(Fountain.Conversations.Provisioning, :preload_acp_adapter, fn _h, _r -> :skip end)

    # A turn's spawn fails cleanly unless the test stubs it — mirroring the
    # pre-facade behavior where spawning against the fake sprite errored and
    # the turn was marked failed. Tests exercising turns re-stub spawn (and
    # write_stdin/close_stdin where their turn writes).
    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _handle, _cmd, _args, _opts ->
      {:error, {:unavailable, :spawn_not_stubbed}}
    end)

    Mimic.stub(Fountain.SandboxSkills, :mount, fn _handle, _runtime, _skills -> :ok end)
    Mimic.stub(Fountain.SandboxSkills, :mount, fn _handle, _runtime, _skills, _opts -> :ok end)

    Mimic.stub(Fountain.SandboxSkills, :reconcile, fn _handle, _runtime, _skills, _previous ->
      {:ok, []}
    end)

    Mimic.stub(Fountain.SandboxSkills, :reconcile, fn _handle, _runtime, _skills, _prev, _opts ->
      {:ok, []}
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _s, _e -> :ok end)

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :clone_repositories, fn _s,
                                                                            _e,
                                                                            _sec,
                                                                            _env,
                                                                            _c ->
      :ok
    end)

    # Per-tenant crypto is exercised in its own tests; here it only needs to
    # succeed so provisioning can proceed.
    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:ok, <<0::256>>} end)
    # The arity the broker's per-request path calls, with its read timeout.
    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _user_id, _opts -> {:ok, <<0::256>>} end)
    Mimic.stub(Fountain.InferenceCredentials, :decrypted_for_user, fn _u, _k -> {:ok, %{}} end)

    handle
  end

  @doc """
  Start a real ConversationServer for `conv` and wait for it to settle.

  Started outside the conversation supervisor, under ExUnit's, so a server that legitimately
  stops doesn't take the test process with it. ExUnit stops any surviving server
  before DataCase releases the SQL Sandbox owner, including on a failed test.
  """
  def start_server(conv, opts \\ []) do
    runtime = Keyword.get(opts, :runtime, Managoat.Runtimes.Testing.FakeRuntime)
    Managoat.Runtimes.Testing.FakeRuntime.observe(self())

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: runtime
    ]

    pid =
      ExUnit.Callbacks.start_supervised!(%{
        id: make_ref(),
        start: {GenServer, :start_link, [Fountain.Conversations.ConversationServer, args]},
        restart: :temporary
      })

    ref = Process.monitor(pid)

    # The prompt is delivered out of band, exactly as production does it: it is
    # not a start_link argument, because Horde replays a stored child spec on
    # every redistribution and would re-run the prompt on each deploy. Since
    # #367 the public API delivers to the pid, so this harness — whose servers
    # are outside the supervisor and invisible to the registry — exercises the exact
    # production path.
    case Keyword.get(opts, :initial_prompt) do
      nil ->
        :ok

      prompt ->
        # `:prompt_opts` is what travels with the prompt to its turn (#1406).
        # Without it this stays the three-argument call, which is the arity
        # the suites that stub `queue_initial_prompt` stub.
        case Keyword.get(opts, :prompt_opts, []) do
          [] ->
            Fountain.Conversations.ConversationServer.queue_initial_prompt(
              pid,
              prompt,
              Keyword.get(opts, :images, [])
            )

          prompt_opts ->
            Fountain.Conversations.ConversationServer.queue_initial_prompt(
              pid,
              prompt,
              Keyword.get(opts, :images, []),
              prompt_opts
            )
        end
    end

    # handle_continue(:provision) runs before any call is answered, so a
    # synchronous call is enough to know provisioning has finished. Let ExUnit's
    # test timeout bound a hung provision: the default five-second system-call
    # timeout mislabeled a slow, live server as :stopped (#1702).
    settled =
      try do
        _ = :sys.get_state(pid, :infinity)
        :alive
      catch
        :exit, _ -> :stopped
      end

    {pid, ref, settled}
  end

  @doc "Wait for a monitored server to stop, or fail the test."
  def assert_stopped(ref, timeout \\ 2_000) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> reason
    after
      timeout -> raise "expected the ConversationServer to stop, but it is still running"
    end
  end
end

defmodule Fountain.ConversationServerCase.ACP do
  @moduledoc "Sandbox transport and ACP protocol helpers for ConversationServer tests."

  import ExUnit.Assertions

  @doc "Wire the sandbox ACP transport to the test process and return its command ref."
  def stub_acp_transport do
    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c ->
      send(test, :stdin_closed)
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    ref
  end

  # The default covers a write on an open connection. A turn that had to spawn
  # a fresh adapter first waits on `check_acp_adapter/3` before its peer says
  # anything, which can outrun a second on a loaded runner — those call sites
  # pass their own.
  def next_write(timeout \\ 1_000) do
    assert_receive {:wrote, line}, timeout
    Jason.decode!(line)
  end

  def reply(pid, ref, id, result) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"
    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  # A message crosses three mailboxes: the server takes the stdout chunk and
  # casts it to the peer, the peer acts and reports back, and the server acts on
  # the report. Syncing only the server would assert against a state one hop
  # behind, which is what made these tests pass alone and fail together.
  #
  # The peer is stopped by the server the moment it reports `{:done, _}`, so
  # between reading `acp_peer` and syncing on it the peer may already be gone
  # (a `noproc` exit from `:sys.get_state/1`, seen in CI on 2026-08-17). That
  # is the state we wanted anyway — the report was handled — so a dead peer
  # is not a failure here.
  def settle(pid) do
    peer = :sys.get_state(pid).acp_peer

    if is_pid(peer) do
      try do
        _ = :sys.get_state(peer)
      catch
        :exit, _ -> :ok
      end
    end

    _ = :sys.get_state(pid)
    :ok
  end

  def notify(pid, ref, update) do
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => "sess_1", "update" => update}
      }) <> "\n"

    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  # initialize → session/new → session/prompt, returning the prompt's id so a
  # test can answer it.
  def drive_to_prompt(pid, ref) do
    %{"id" => init_id, "method" => "initialize"} = next_write()

    reply(pid, ref, init_id, %{
      "agentCapabilities" => %{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}
    })

    %{"id" => new_id, "method" => "session/new"} = next_write()
    reply(pid, ref, new_id, %{"sessionId" => "sess_1", "models" => %{}})
    %{"id" => set_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, set_id, %{})

    %{"id" => prompt_id, "method" => "session/prompt"} = next_write()
    settle(pid)
    prompt_id
  end
end
