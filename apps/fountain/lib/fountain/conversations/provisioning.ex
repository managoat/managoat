defmodule Fountain.Conversations.Provisioning do
  @moduledoc """
  Provisioning steps that run inside a freshly-created sandbox, before the
  runtime CLI is spawned. Each step publishes its own stage events so the
  UI/SSE clients can show progress.

  Order in `FreshProvision.run_provisioning_pipeline/6`, after the sandbox
  config (runtime config, instructions, env file, broker CA and sudoers) is
  on the disk:
    1. `apply_broker_floor/2` (sandbox API call —
       fast). First, so that nothing the tenant chose runs on the open
       network: apt and npm reach their mirrors through the proxy, which the
       CA and the sudoers `env_keep` already installed make possible.
    2. `install_packages/4` (apt/npm, through the proxy)
    3. `clone_repositories/4` (git clone — slow)
    4. user's `setup_script` (whatever they supplied)
  Skills are written beside the pipeline and awaited at its end. The
  runtime's ACP adapter (`prepare_acp_adapter/3`) installs beside steps 2–4,
  once the floor is applied, and the runtime's own files
  (`prepare_runtime_sandbox/7`) are written after them.

  Each step is a no-op when the corresponding field is empty, so legacy
  environments with bare config (just a name) provision instantly.

  Since #1372 the steps the server used to carry itself live here too, in
  the section at the end: recording the machine's URL on the row
  (`record_sandbox_url/3`), step 5 (`run_setup_script/4`), step 6
  (`write_runtime_config/3`), the agent's instructions file
  (`write_instructions/3`) and the runtime's own preparation once the pipeline
  is done (`prepare_runtime_sprite/7`, which installs the ACP adapter first).
  The environment they are handed is `Fountain.Conversations.SpriteEnv`'s.

  Two of those steps left again in ADR 0058 stage 7b, and they are the two that
  were not steps *inside* a sandbox at all: creating the machine, and tearing
  down the remnant of an interrupted attempt before creating it again. Both are
  mutations of the machine itself, which is the owner's, and they are now
  `Fountain.Machines.Provision`'s — where they sit between the lease that makes
  them safe and the compare-and-set that records them.

  Everything here talks to the sandbox through `Managoat.Sandbox`; nothing
  provider-shaped (rule structs, exec streams) appears at this level.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.StageOutput
  alias Fountain.Environments.Environment
  alias Fountain.Workspaces.SetupOutput
  alias Managoat.Sandbox.Retry
  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy

  require Logger

  @env_file "/home/sprite/.env"

  # One lock file for the machine, not for the conversation: the trust
  # bundle, sudoers drop-in and git config are shared by every setup.
  @ca_lock "/tmp/fountain-broker-ca.lock"

  @doc """
  Write the machine's env (runtime defaults + env_vars + secrets) to
  `/home/sprite/.env` so a `setup_script` that does `source .env` picks up
  the variables. Mirrors the legacy AoD's `env_file.py`.

  The per-conversation identity — `MANAGOAT_TOKEN`, `MANAGOAT_CONVERSATION_ID`,
  `TRACEPARENT`, the broker proxy address and the inference credential — is
  not in this file: callers pass the env through
  `Fountain.Conversations.Identity.disk_env/1` first. The file is shared by
  every conversation on the machine; the identity reaches each process as
  spawn env instead, `run_setup_script/4` included.

  Written with mode 600, and `chmod 600` again after the write as defense
  in depth — other sandbox users (if any) must not be able to read tokens.
  """
  def write_env_file(handle, nil), do: write_env_file(handle, [])

  def write_env_file(handle, sprite_env) do
    :ok = SetupOutput.step(:environment)
    body = render_env_file(sprite_env)

    case Retry.with_backoff(fn -> Sandbox.write_file(handle, @env_file, body, mode: 0o600) end,
           label: "env file write"
         ) do
      :ok ->
        # Ignore chmod errors — we still wrote the file (already mode 600).
        # Defense in depth, not a hard requirement.
        _ = Sandbox.exec(handle, "chmod", ["600", @env_file], timeout: 5_000)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def render_env_file(sprite_env) do
    sprite_env
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{shell_escape_value(to_string(v))}" end)
    |> Kernel.<>("\n")
  end

  # Always single-quote, escaping inner single quotes as '\''.
  #
  # This previously detected `$`, backtick and backslash and then wrapped the
  # value in *double* quotes, where all three remain active. The file is
  # explicitly meant to be `source`d by a user's setup_script, so a secret whose
  # value contained $(...) or `...` executed on source. A value containing a
  # newline also silently corrupted the file, since nothing quoted it.
  #
  # Single quotes are inert in shell: the only character needing treatment is
  # the single quote itself, and newlines survive intact.
  defp shell_escape_value(v), do: shell_quote(v)

  # ── packages ──────────────────────────────────────────────────────────────

  @doc """
  Install OS / language packages declared on the env. Recognized keys:

      packages: %{
        "apt" => ["jq", "ripgrep"],
        "npm" => ["typescript", "@anthropic-ai/sdk"]
      }

  Anything else is silently ignored. Returns `:ok` on success, `{:error,
  {step, exit_code, tail}}` on first failure, `tail` being the last 2 kB the
  command printed (all of it is in the log; the sandbox is kept alive so the
  caller can decide whether to destroy).
  """
  def install_packages(_handle, nil, _sprite_env, _conv_id), do: :ok

  def install_packages(handle, %Environment{} = env, sprite_env, conv_id) do
    case build_package_commands(env.packages || %{}) do
      [] ->
        :ok

      cmds ->
        Fountain.Telemetry.span(
          [:packages],
          %{conv_id: conv_id, commands: length(cmds)},
          fn ->
            :ok = SetupOutput.step(:packages)
            publish_stage(conv_id, "packages", "started", %{commands: length(cmds)})

            result =
              Enum.reduce_while(cmds, :ok, fn cmd, _ ->
                # Retried: apt-get install -y and npm install -g are safe to
                # re-run. A non-zero exit comes back as {:ok, code} and is
                # handled below, not retried — only a failure to reach the
                # sandbox at all is. Output streams into the log as it comes
                # (#2550), so a retry after a dropped connection shows what
                # the first attempt printed, then the second's. An exec that
                # ran out its timeout is not retried: the deadline stops only
                # the local collector, so the first apt-get may still hold the
                # dpkg lock in the sandbox (#2972).
                Retry.with_backoff(
                  fn ->
                    case exec_streamed(handle, conv_id, "packages", "fountain-packages", cmd,
                           env: sprite_env,
                           timeout: 300_000
                         ) do
                      {{:ok, code}, tail} -> {:ok, code, tail}
                      {{:error, reason}, _tail} -> {:error, reason}
                    end
                  end,
                  label: "package install",
                  retriable?: &package_retriable?/1
                )
                |> case do
                  {:ok, 0, _tail} ->
                    {:cont, :ok}

                  {:ok, code, tail} ->
                    {:halt, {:error, {:packages, code, tail}}}

                  {:error, reason} ->
                    {:halt, {:error, {:packages_unreachable, reason}}}
                end
              end)

            case result do
              :ok ->
                publish_stage(conv_id, "packages", "done")
                {:ok, %{outcome: :ok}}

              {:error, {:packages, code, _}} = err ->
                publish_stage(conv_id, "packages", "failed", %{exit_code: code})
                {err, %{outcome: :failed, exit_code: code}}

              {:error, reason} = err ->
                publish_stage(conv_id, "packages", "failed", %{reason: inspect(reason)})
                {err, %{outcome: :failed, reason: inspect(reason)}}
            end
          end
        )
    end
  end

  defp package_retriable?({:unavailable, {:exec_timeout, _ms}}), do: false
  defp package_retriable?(reason), do: Retry.transient?(reason)

  @doc false
  def build_package_commands(%{} = pkgs) do
    apt_cmds = build_apt_commands(Map.get(pkgs, "apt", []))
    npm_cmds = build_npm_commands(Map.get(pkgs, "npm", []))
    apt_cmds ++ npm_cmds
  end

  def build_package_commands(_), do: []

  @package_managers ~w(apt npm)

  @doc """
  The package managers `install_packages/4` acts on. An environment's
  `packages` map may carry other keys (the form used to offer pip, cargo, gem
  and go); they are stored and ignored — nothing installs them (#815).
  """
  def package_managers, do: @package_managers

  # A Debian package name, optionally with its architecture. Anything else
  # (a version pin `jq=1.7`, a release `jq/noble-backports`, a pattern) takes
  # the full update-and-install path, since `dpkg-query` would read it
  # differently from `apt-get`.
  @plain_package ~r/\A[a-z0-9][a-z0-9+.\-]*(:[a-z0-9\-]+)?\z/

  @doc false
  def build_apt_commands([]), do: []

  def build_apt_commands(list) when is_list(list) do
    names = Enum.filter(list, &is_binary/1)
    quoted = Enum.map_join(names, " ", &shell_quote/1)

    install =
      "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq #{quoted}"

    cond do
      quoted == "" ->
        []

      Enum.all?(names, &Regex.match?(@plain_package, &1)) ->
        [skip_installed(names, quoted, install)]

      true ->
        [install]
    end
  end

  # When every package asked for is already installed, which the base image
  # makes common (`jq`, `git`, `curl`, `make`, `gcc`, `python3` all ship in
  # the Sprites image), the install is skipped. Otherwise the
  # `apt-get update` alone was ~3 s on a fresh sprite, whose lists are as old
  # as its image, and the install that then did nothing ~1.7 s more: +5.7 s
  # of cold start for `apt: ["jq"]` (measured 2026-10-15). What a skip gives
  # up is the upgrade an install of an installed package would have made to
  # the archive's newer version, if there was one; the package stays at the
  # image's. `dpkg-query` must answer for every name, each line `installed`.
  defp skip_installed(names, quoted, install) do
    check =
      "s=$(dpkg-query -W -f='${db:Status-Status}\\n' -- #{quoted} 2>/dev/null) && " <>
        "[ \"$(printf '%s\\n' \"$s\" | grep -cx installed)\" = #{length(names)} ]"

    "if #{check}; then echo #{shell_quote("already installed: " <> Enum.join(names, " "))}; " <>
      "else #{install}; fi"
  end

  @doc false
  def build_npm_commands([]), do: []

  def build_npm_commands(list) when is_list(list) do
    quoted = list |> Enum.filter(&is_binary/1) |> Enum.map_join(" ", &shell_quote/1)
    if quoted == "", do: [], else: ["npm install -g --no-progress --silent #{quoted}"]
  end

  # ── network policy ────────────────────────────────────────────────────────

  @doc """
  Refuse a pairing the broker cannot enforce, before a sandbox exists
  (ADR 0019 gate 1a). Every conversation is brokered (amendment of
  2026-10-15), so this runs on every launch and every wake.

  Two refusals, each by name: a provider with no `:network_policy`, since
  placeholders without the floor are half a control; and a broker that does
  not answer `/health`, so an outage is reported as one
  rather than as the install failure it would otherwise wear (§6). A
  `limited` environment is not refused since gate 2: its `allowed_hosts` are
  enforced at the broker (`Fountain.Broker.network_for/1`).
  """
  @spec check_broker_support(atom(), String.t() | nil) ::
          :ok | {:error, {:broker, atom()} | {:broker, :unreachable, term()}}
  def check_broker_support(provider, conv_id) do
    cond do
      not Sandbox.supports?(provider, :network_policy) ->
        publish_stage(conv_id, "broker", "failed", %{
          provider: to_string(provider),
          reason: "backend_lacks_network_policy"
        })

        {:error, {:broker, :backend_lacks_network_policy}}

      true ->
        case Fountain.Broker.preflight() do
          :ok ->
            :ok

          {:error, {:broker, :unreachable, detail}} = err ->
            publish_stage(conv_id, "broker", "failed", %{
              reason: "broker_unreachable",
              detail: inspect(detail)
            })

            err
        end
    end
  end

  @doc """
  The network floor of a brokered sandbox: the broker's host is the one
  domain it may reach, whatever the environment's `networking_type` says
  (ADR 0019 §2). On a provider without `:network_policy` this is skipped;
  `check_broker_support/2` has already refused a launch there.
  """
  @spec apply_broker_floor(Handle.t(), String.t() | nil) :: :ok | {:error, term()}
  def apply_broker_floor(handle, conv_id) do
    :ok = SetupOutput.step(:broker)
    host = Fountain.Broker.proxy_host()

    if Sandbox.supports?(handle, :network_policy) do
      Fountain.Telemetry.span(
        [:network_policy],
        %{conv_id: conv_id, hosts: 1},
        fn ->
          publish_stage(conv_id, "network", "started", %{type: "broker", hosts: 1})

          case Retry.with_backoff(
                 fn -> Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: [host]}) end,
                 label: "broker network floor"
               ) do
            :ok ->
              publish_stage(conv_id, "network", "done", %{type: "broker"})
              {:ok, %{outcome: :ok}}

            {:error, reason} ->
              publish_stage(conv_id, "network", "failed", %{reason: inspect(reason)})
              {{:error, {:network_policy, reason}}, %{outcome: :failed, reason: inspect(reason)}}
          end
        end
      )
    else
      publish_stage(conv_id, "network", "done", %{type: "broker", enforced: false})
      :ok
    end
  end

  # Add one CA to a Debian trust store without rebuilding it: append it to the
  # bundle, and link it by subject hash the way c_rehash would (the next free
  # `.N`, or none if a link already names it). The link is best-effort; the
  # bundle is what TLS clients read. `$1` is the CA, `$2` the bundle.
  @add_to_trust_store ~S"""
  cat "$1" >> "$2" &&
  if h=$(openssl x509 -hash -noout -in "$1" 2>/dev/null); then
    d=$(dirname "$2"); i=0
    while [ "$i" -lt 10 ]; do
      l="$d/$h.$i"
      if [ -L "$l" ] && [ "$(readlink "$l")" = "$1" ]; then break; fi
      if [ ! -e "$l" ] && [ ! -L "$l" ]; then ln -s "$1" "$l"; break; fi
      i=$((i + 1))
    done
  fi
  """

  @doc false
  def add_to_trust_store, do: @add_to_trust_store

  @doc """
  Put the broker's root CA in the sandbox's operating-system trust store,
  and let `sudo` keep the proxy variables.

  Gate 0 found that one `update-ca-certificates` satisfies curl, git and npm
  at once, where per-tool variables each fail in their own way. Node is the
  exception and reads `NODE_EXTRA_CA_CERTS`, which `Fountain.Broker.ca_env/0`
  points at the same file.

  It runs under a lock, and rebuilds the trust store only when the bundle it
  has is not the one this CA produces (#1674). Both halves concern the shared
  sandbox (ADR 0023): every conversation on the machine runs this on
  provision *and* on reattach, and `update-ca-certificates` builds the trust
  bundle in a fixed temporary file (`ca-certificates.crt.new`) before
  renaming it into place. Two runs at once therefore share that path — one
  truncates what the other is still writing, and the rename publishes a
  bundle of five certificates where there should be 122. A client that reads
  it in that state has no broker root and fails every request with
  `UnknownIssuer`, then waits out a full idle timeout before retrying. It was
  one read in six on a sandbox with forty conversations.

  Three details, each of which was wrong in an earlier cut of this:

    * **The marker holds the bundle's digest, not a flag.** The CA is derived
      from the deployment's master key, so comparing it proves the *source*
      is unchanged — not that the bundle still contains it. `apt` running
      `ca-certificates`' postinst, and any tenant `setup_script`, rebuild
      that bundle outside this lock. Recording `sha256sum` of the bundle
      means any later change to it re-arms the guard and the next
      conversation repairs the machine. A sandbox already damaged before this
      shipped has no marker at all, and repairs on its next wake.
    * **`flock` failing is two conditions, and they are not the same.** The
      binary being absent is a sandbox that should provision the way it did
      before, not fail: it rebuilds unlocked and stamps nothing, so the next
      conversation rebuilds too. The 120-second wait expiring is the
      opposite — somebody is holding the lock precisely because they are
      mid-rebuild, and rebuilding anyway is the concurrent write this exists
      to prevent. Worse, the holder stamps `sha256sum` after its own
      `update-ca-certificates` returns, so a waiter that publishes a
      truncated bundle in between gets it recorded as good and nothing ever
      repairs it. A timeout therefore exits 75 and touches nothing. The
      conversation fails loudly, which is recoverable; a trust store
      truncated for every conversation on the machine is not.
    * **The staging file is per invocation.** It is written outside the lock,
      so a fixed path is the same bug one level up: two conversations writing
      it at once can hand each other a torn file to compare and install. The
      subshell's `EXIT` trap removes it, and the error arm removes it for an
      exec that never reached bash.

  Hold that same lock through the sudoers install and git configuration.
  They also write shared files: releasing it after the CA rebuild lets
  concurrent wakes collide on the sudoers destination or `.gitconfig.lock`
  (#1671). The work stays `&&`-chained, so its exit status is still what the
  caller sees.

  It also pins git's `http.proxyAuthMethod` to `basic`. git defaults to
  `anyauth`, which by definition cannot send a credential until it has seen a
  `407` naming the scheme: it sends CONNECT bare, reads the challenge, and
  retries on the same connection. The native broker closes the connection
  after a `407`, so the retry lands on a dead socket and git reports
  `Proxy CONNECT aborted` — which is every brokered clone, on an environment
  with a repository, failing to provision. Agent Vault kept the connection
  open and answered the retry, which is why this only appeared at the flip
  (#1485). `basic` makes libcurl send the credential preemptively, the way
  the curl binary already did, so the first CONNECT carries it and no retry
  is needed. The broker's own keep-alive gap is worth closing too, but this
  is the half that does not need a library release, and it is the half that
  makes the client stop depending on the server's 407 behaviour at all.

  The sudoers drop-in is what lets a setup script's `sudo apt-get install`
  reach a mirror at all: sudo's `env_reset` strips `http_proxy` and friends,
  apt then resolves the mirror directly, and the broker floor (only the
  broker's host is reachable) refuses it as `Temporary failure resolving`.
  The first brokered provisions of a real environment failed exactly there.
  `env_keep` preserves the variables for the sudo'd process without writing
  the session token anywhere, which an `apt.conf` proxy entry would do. The
  file is checked with `visudo -c` before it is installed, since a bad
  sudoers fragment disables sudo outright.
  """
  @spec install_broker_ca(Handle.t(), String.t() | nil) :: :ok | {:error, term()}
  def install_broker_ca(handle, conv_id) do
    :ok = SetupOutput.step(:broker)
    path = Fountain.Broker.ca_path()
    staging = Fountain.Broker.ca_staging_path() <> "." <> Ecto.UUID.generate()
    bundle = Fountain.Broker.system_ca_bundle()
    marker = path <> ".trust-store-ready"
    cleanup = "rm -f -- #{shell_quote(staging)}"
    stamp = "sha256sum #{shell_quote(bundle)} > #{shell_quote(marker)}"

    # Written as the sandbox user where it may, then moved into the root-owned
    # trust directory the way `install_packages/4` reaches apt: through sudo.
    #
    # A sandbox that has never trusted the CA (every fresh provision) gets it
    # added to the existing bundle and linked by hash, which is what
    # `update-ca-certificates` would produce for it: ~50 ms against the
    # 1.3–2.7 s that rebuilding all ~240 entries costs on a sprite (measured
    # 2026-09-26; the image has no update.d hooks). Anything else — a changed
    # CA, a bundle that no longer matches the marker — still rebuilds, which
    # is what repairs a corrupted bundle and drops a replaced CA.
    install =
      "( trap #{shell_quote(cleanup)} EXIT; safe=0; " <>
        "if command -v flock >/dev/null 2>&1; then flock -w 120 9 || exit 75; safe=1; fi; " <>
        "{ #{same_ca_key(staging, path)} && " <>
        "sha256sum -c --status #{shell_quote(marker)} 2>/dev/null; } || " <>
        "{ sudo rm -f -- #{shell_quote(marker)} && " <>
        "if [ ! -e #{shell_quote(path)} ] && [ -s #{shell_quote(bundle)} ]; then " <>
        "sudo install -D -m 644 #{shell_quote(staging)} #{shell_quote(path)} && " <>
        "sudo sh -c #{shell_quote(@add_to_trust_store)} add #{shell_quote(path)} #{shell_quote(bundle)}; " <>
        "else " <>
        "sudo install -D -m 644 #{shell_quote(staging)} #{shell_quote(path)} && " <>
        "sudo update-ca-certificates; fi && " <>
        ~s({ [ "$safe" = 1 ] && sudo sh -c ) <>
        shell_quote(stamp) <>
        " || true; }; } && " <>
        sudo_env_keep_command() <>
        " && " <>
        git_proxy_auth_command() <>
        " ) 9>#{shell_quote(@ca_lock)}"

    with {:ok, pem} <- Fountain.Broker.ca_pem(),
         :ok <-
           Retry.with_backoff(fn -> Sandbox.write_file(handle, staging, pem, mode: 0o644) end,
             label: "broker CA write"
           ) do
      case Sandbox.exec(handle, "bash", ["-c", install],
             stderr_to_stdout: true,
             timeout: 150_000
           ) do
        {:ok, _out, 0} ->
          :ok

        {:ok, out, code} ->
          publish_stage(conv_id, "broker", "failed", %{reason: "ca_install_exit", exit_code: code})

          {:error, {:broker, :ca_install_exit, code, String.slice(to_string(out), 0, 500)}}

        {:error, reason} ->
          # The trap runs inside bash; a transport failure or an expired
          # budget means bash may never have started, and the staged PEM has
          # a name no later invocation will reuse. Best effort, and only
          # worth anything if the sandbox is reachable again by now.
          _ = Sandbox.exec(handle, "rm", ["-f", "--", staging], timeout: 5_000)
          publish_stage(conv_id, "broker", "failed", %{reason: "ca_install_unreachable"})
          {:error, {:broker, :ca_install, reason}}
      end
    else
      {:error, reason} = err ->
        publish_stage(conv_id, "broker", "failed", %{reason: inspect(reason)})
        err
    end
  end

  # Whether the CA at `installed` is the one at `staged`, compared the way a
  # TLS client matches a trust anchor: by public key. The bytes cannot be
  # compared. `Managoat.Broker.CA` derives the key, subject, serial and
  # validity from the seed, but ECDSA signing is randomised, so every
  # derivation is a different PEM. Compared with `cmp`, the installed CA never
  # matched the one about to be written, and every provision and every wake
  # rebuilt the whole system trust store: ~1.5–2.3 s of each wake, measured on
  # 2026-10-07. An empty key (no `openssl`, or a file that does not parse) is
  # never a match, so a machine without `openssl` rebuilds as before.
  defp same_ca_key(staged, installed) do
    "{ staged_key=$(openssl x509 -noout -pubkey -in #{shell_quote(staged)} 2>/dev/null) && " <>
      "installed_key=$(openssl x509 -noout -pubkey -in #{shell_quote(installed)} 2>/dev/null) && " <>
      ~s([ -n "$staged_key" ] && [ "$staged_key" = "$installed_key" ]; })
  end

  # Global, so it covers the agent's own `git push`/`fetch` inside the sandbox
  # and not only the clone provisioning runs. Written to the sprite user's
  # ~/.gitconfig, which git reads whatever XDG_CONFIG_HOME says.
  defp git_proxy_auth_command,
    do: "git config --global http.proxyAuthMethod basic"

  @doc "The CA files a brokered sandbox's env names: the OS trust store."
  @spec broker_ca_files(Handle.t() | nil) :: {:ok, Fountain.Broker.ca_files()}
  def broker_ca_files(_handle), do: {:ok, Fountain.Broker.system_ca_files()}

  @sudoers_staging "/tmp/fountain-broker-proxy.sudoers"
  @sudoers_path "/etc/sudoers.d/fountain-broker-proxy"

  @doc "The sudoers drop-in that keeps `Fountain.Broker.env_keys/0` across `sudo`."
  @spec sudoers_path() :: String.t()
  def sudoers_path, do: @sudoers_path

  defp sudo_env_keep_command do
    keep = Enum.join(Fountain.Broker.env_keys(), " ")
    line = ~s(Defaults env_keep += "#{keep}")

    "printf '%s\\n' #{shell_quote(line)} > #{shell_quote(@sudoers_staging)} && " <>
      "sudo visudo -cf #{shell_quote(@sudoers_staging)} && " <>
      "sudo install -m 440 #{shell_quote(@sudoers_staging)} #{shell_quote(@sudoers_path)}"
  end

  # ── git clone ─────────────────────────────────────────────────────────────

  @doc """
  Clone every repository declared on the env into the sandbox at its
  `mount_path`. HTTPS only, x-access-token auth via the env secret named
  by `secret_key`. Returns `:ok` or `{:error, ...}` on first failure.
  """
  def clone_repositories(_handle, nil, _secrets, _sprite_env, _conv_id), do: :ok

  def clone_repositories(
        _handle,
        %Environment{repositories: repos},
        _secrets,
        _sprite_env,
        _conv_id
      )
      when repos in [nil, []],
      do: :ok

  def clone_repositories(handle, %Environment{repositories: repos}, secrets, sprite_env, conv_id) do
    Fountain.Telemetry.span(
      [:clone_repositories],
      %{conv_id: conv_id, count: length(repos)},
      fn ->
        :ok = SetupOutput.step(:repositories)
        publish_stage(conv_id, "clone", "started", %{count: length(repos)})

        result =
          Enum.reduce_while(repos, :ok, fn repo, _ ->
            case clone_one(handle, repo, secrets, sprite_env, conv_id) do
              :ok -> {:cont, :ok}
              err -> {:halt, err}
            end
          end)

        case result do
          :ok ->
            publish_stage(conv_id, "clone", "done")
            {:ok, %{outcome: :ok}}

          {:error, reason} = err ->
            publish_stage(conv_id, "clone", "failed", %{reason: inspect(reason)})
            {err, %{outcome: :failed, reason: inspect(reason)}}
        end
      end
    )
  end

  # https + token is the only clone mechanism. An SSH path (key-from-secret,
  # pinned host keys) existed here fully implemented but was unreachable —
  # validation has required https:// since the schema was written, and nobody
  # ever got an ssh repo past it. Deleted rather than enabled (#228): the use
  # case is covered by token auth, and enabling it would first have required
  # establishing that limited networking permits SSH at all. The implementation
  # lives in git history if real demand ever shows up.
  defp clone_one(handle, %{"url" => url} = repo, secrets, sprite_env, conv_id) do
    if is_binary(url) and String.starts_with?(url, "https://") do
      clone_https(handle, repo, secrets, sprite_env, conv_id)
    else
      {:error, {:clone_unsupported_url, url}}
    end
  end

  defp clone_one(_, repo, _, _, _), do: {:error, {:clone_invalid_spec, repo}}

  # `env:` is passed for the same reason every other step passes it: a
  # brokered clone reaches GitHub only through `HTTPS_PROXY`, and git reads
  # that from its environment. It was the one step that ran bare.
  #
  # `-c http.proxyAuthMethod=basic` repeats what `install_broker_ca/2` writes
  # globally, on purpose: the clone must not depend on that step having run,
  # and it is inert when the conversation is not brokered (there is no proxy
  # to authenticate to). The moduledoc there explains what git's `anyauth`
  # default does to a proxy that closes the connection after a 407.
  defp clone_https(
         handle,
         %{"url" => url, "mount_path" => mount} = repo,
         secrets,
         sprite_env,
         conv_id
       ) do
    auth_url = inject_token(url, repo["secret_key"], secrets)

    cmd =
      git_env_prefix() <>
        "mkdir -p #{shell_quote(Path.dirname(mount))} && " <>
        "git -c http.proxyAuthMethod=basic clone --depth 50 " <>
        "#{branch_arg(repo)}#{shell_quote(auth_url)} #{shell_quote(mount)}"

    # Retried only when nothing was written, so that `mount` is still exactly
    # as this step found it. `Retry`'s moduledoc says never to wrap a git
    # clone, and it is right about the case it means: a clone that started
    # and failed partway leaves a half-written directory, and a second clone
    # into it is not the same operation. That case is not retried. Two are:
    #
    # - The sprite refused the exec, so no command started (`never_started?/1`).
    #   A freshly created sprite answers 503 ("service temporarily
    #   unavailable, please retry", Retry-After: 1) for its first several
    #   seconds; every other provisioning step already rode that out, and the
    #   clone was the one that failed the conversation (#2491).
    # - git ran but never reached the remote, so it wrote nothing (git
    #   removes the directory it made). On Sprites, the first connection
    #   through a just-applied broker floor is sometimes refused outright,
    #   measured at about 2 in 5 after a package install; the next one lands.
    #
    # Everything else is final on the first attempt: `:timeout` above all,
    # which can fire with a clone half-done, and which `Retry`'s default
    # classifier would otherwise treat as transient.
    result =
      Retry.with_backoff(
        fn ->
          case Sandbox.exec(handle, "bash", ["-c", login_script(cmd)],
                 env: sprite_env,
                 stderr_to_stdout: true,
                 timeout: 600_000
               ) do
            {:ok, output, code} ->
              log_output(conv_id, "clone", scrub_token(output))
              # An explicit workspace's setup log (#3009), which redacts it too.
              :ok = SetupOutput.output(scrub_token(output))
              :ok = SetupOutput.flush()

              cond do
                code == 0 -> :ok
                never_connected?(output) -> {:error, {:clone_connect, code}}
                true -> {:error, {:clone, url, code}}
              end

            {:error, reason} ->
              {:error, {:clone_unreachable, url, reason}}
          end
        end,
        label: "git clone",
        retriable?: &clone_retriable?/1
      )

    case result do
      {:error, {:clone_connect, code}} -> {:error, {:clone, url, code}}
      other -> other
    end
  end

  defp clone_retriable?({:clone_connect, _code}), do: true
  defp clone_retriable?({:clone_unreachable, _url, reason}), do: never_started?(reason)
  defp clone_retriable?(_reason), do: false

  # Reasons that prove `Sandbox.exec` never started a command, so retrying it
  # repeats nothing. Deliberately narrower than `Retry.transient?/1`, whose
  # "unknown shapes are transient" default is the right call for an idempotent
  # step and the wrong one for a clone.
  defp never_started?({:unavailable, _detail}), do: true
  defp never_started?({:rate_limited, _retry_after}), do: true

  # The adapter's unclassified escape hatch (`{:provider, provider, term}`) —
  # a status the sprite answered with rather than a classification, so read it
  # directly: 429 and 5xx are the front door turning the request away.
  defp never_started?({:provider, _provider, %{status: status}}) when is_integer(status),
    do: status == 429 or status >= 500

  defp never_started?(_reason), do: false

  # curl's words, through git, for a connection that never opened: to the
  # proxy, or to the host itself.
  @never_connected ["Could not connect to server", "Connection refused", "Could not resolve"]

  defp never_connected?(output),
    do: output =~ "unable to access" and String.contains?(output, @never_connected)

  # The sprite user can't read `/home/sprite/.config/git/ignore` (parent
  # dir's perms reject the access(2) check even though most writes go
  # through), so git emits "warning: unable to access ..." on every
  # clone. Pin XDG_CONFIG_HOME to /tmp where git can actually stat the
  # path; missing files are fine (git treats absent global ignore as
  # "no global ignore"), it's the EACCES that produces the warning.
  defp git_env_prefix do
    "export XDG_CONFIG_HOME=/tmp; "
  end

  defp branch_arg(repo) do
    case repo["ref"] do
      ref when is_binary(ref) and ref != "" -> "-b #{shell_quote(ref)} "
      _ -> ""
    end
  end

  @doc false
  def inject_token(url, nil, _), do: url
  def inject_token(url, "", _), do: url

  def inject_token(url, key, secrets) when is_map(secrets) do
    case Map.get(secrets, key) do
      nil -> url
      "" -> url
      token -> rewrite_https_with_token(url, token)
    end
  end

  def inject_token(url, _, _), do: url

  @doc false
  def rewrite_https_with_token("https://" <> rest, token) do
    "https://x-access-token:#{token}@" <> rest
  end

  def rewrite_https_with_token(url, _), do: url

  # Avoid leaking the token into log_events when git's clone output echoes
  # the URL back (it sometimes does on auth errors).
  @doc false
  def scrub_token(s) when is_binary(s),
    do: Regex.replace(~r{https://x-access-token:[^@]+@}, s, "https://x-access-token:***@")

  def scrub_token(s), do: s

  # ── helpers ───────────────────────────────────────────────────────────────

  @doc false
  def shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  # ── the machine, its URL and the runtime's files (#1372) ──────────────────
  #
  # The steps ConversationServer used to carry itself: creating the sandbox,
  # recording its URL, the user's setup script and the files the runtime
  # needs before its first turn. Same bodies, now beside the pipeline they
  # are steps of.

  # Best-effort, and deliberately not fatal: a sandbox with no reportable URL
  # is still a working sandbox. Stored on the row so the API and the UI can
  # show it without a provider round trip.
  #
  # Written under the provision's own lease epoch since ADR 0058 stage 7b, by
  # compare-and-set, like every other write a machine's owner makes mid-
  # operation. Two things change
  # with it. A superseded attempt's URL is no longer written over the machine
  # another owner is building — the row's `provider_meta` would otherwise name
  # a host this attempt created and then destroyed. And a reset fence landing
  # in this window is no longer a `MatchError`: `update_sandbox/2` rolled back
  # with `:sandbox_reset_pending` here and the `{:ok, _} =` above it raised,
  # which the server's outer rescue turned into a failed conversation. The URL
  # is a convenience; a refusal to record it is logged and the provision
  # carries on to the finalize, which is where a fence is answered properly.
  def record_sandbox_url(sandbox, handle, epoch) do
    case Managoat.Sandbox.public_url(handle) do
      {:ok, url} ->
        meta = Map.put(sandbox.provider_meta || %{}, "public_url", url)

        case Fountain.Machines.Lease.cas_update(sandbox.id, epoch, provider_meta: meta) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            # `warning`, not `info`: this attempt has lost the machine, which
            # means its pipeline is about to discover the same thing at its
            # finalize. Worth a line an operator sees.
            Logger.warning(
              "sandbox #{sandbox.id}: not recording the machine URL (#{inspect(reason)})"
            )
        end

        url

      {:error, :unsupported} ->
        nil

      {:error, reason} ->
        Logger.warning("could not read the sandbox URL for #{handle.name}: #{inspect(reason)}")
        nil
    end
  rescue
    # The URL is a convenience; provisioning is not. An adapter that raises
    # here — a provider SDK surprise, a probe against a sandbox that has not
    # settled — must not cost the user their conversation.
    error ->
      Logger.warning("sandbox URL lookup raised for #{handle.name}: #{inspect(error)}")
      nil
  end

  # The steps whose output is the user's to read (a package install, a clone,
  # the setup script) run their command in a login shell, as they always have:
  # that is what puts the sandbox's own PATH and the image's language
  # variables on it (`NVM_DIR`, on a sprite). But a step's output is what its
  # command printed, not what the startup files printed on the way in (#3026).
  # A sprite's `~/.profile` sources its `~/.bashrc`, which runs `bind`
  # unguarded, and bash warns "line editing not enabled" for that in any
  # shell that is not interactive: two lines at the top of every step, and two
  # of the lines a failed setup script's error quotes.
  #
  # So the login shell reads its startup files with stderr on /dev/null, and
  # gets it back before the command's first line. Bash reads `BASH_ENV` after
  # a non-interactive login shell's profiles and before the `-c` command; this
  # one puts stderr back from fd 3, where it waited, and unsets itself so that
  # no shell the command starts reads it. The command still runs in the login
  # shell itself, exactly as `bash -lc` ran it: the same `$0` and arguments,
  # the profiles' functions and unexported variables. What a startup file
  # prints on stdout still shows; what it prints on stderr, its own errors
  # included, does not.
  @login_shell ~S"""
  login_shell() {
    local startup rc
    startup=$(mktemp) || return 1
    printf '%s\n' 'exec 2>&3 3>&-' 'unset BASH_ENV' >"$startup"
    BASH_ENV=$startup bash -lc "$1" 3>&2 2>/dev/null
    rc=$?
    rm -f -- "$startup"
    return "$rc"
  }
  """

  @doc false
  # The shell for `bash -c` that runs `cmd` in `@login_shell`.
  def login_script(cmd), do: @login_shell <> "login_shell " <> shell_quote(cmd) <> "\n"

  # The setup step ends when the user's script exits, not when the exec's
  # output pipe closes (#2558). A process the script leaves running — a dev
  # server, a keepalive loop, a `sleep` it killed the parent of — inherits that
  # pipe, and an exec collects output until EOF: a provision waited up to 30 s
  # on a lingering `sleep 30`, and a server started with `&` held it until the
  # setup timeout failed it. So the script writes to a private file instead;
  # anything still running keeps the unlinked file, not the step. stdin is
  # closed for the same reason.
  #
  # The file is sent on as it grows (#2550): about once a second, whatever the
  # script has printed since the last send, and the rest once it exits. The
  # loop polls every 0.1 s so the step still ends within that of the script.
  @stream_wrapper ~S"""
  out=$(mktemp) || exit 1
  login_shell "$1" >"$out" 2>&1 </dev/null &
  pid=$!
  sent=0
  send_new() {
    size=$(wc -c <"$out") || return 0
    if [ "$size" -gt "$sent" ]; then
      tail -c +"$((sent + 1))" "$out" | head -c "$((size - sent))"
      sent=$size
    fi
  }
  ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    ticks=$((ticks + 1))
    if [ "$ticks" -ge 10 ]; then
      send_new
      ticks=0
    fi
  done
  wait "$pid"
  rc=$?
  send_new
  rm -f "$out"
  exit "$rc"
  """

  @doc false
  def stream_wrapper, do: @login_shell <> @stream_wrapper

  def run_setup_script(_handle, nil, _sprite_env, _conv_id), do: :ok
  def run_setup_script(_handle, %{setup_script: ""}, _sprite_env, _conv_id), do: :ok

  # The script runs with `MANAGOAT_RUNTIME_TEMPLATE` set, and the template's
  # runtime directories are made, empty, in the same exec just before it
  # (#2998): what it writes there is copied into each conversation's config
  # home when the home is made (`Managoat.Runtimes.Template`). Last in the
  # env, so the template is where Managoat looks whatever the tenant's own
  # variables say.
  def run_setup_script(handle, %{setup_script: script} = environment, sprite_env, conv_id) do
    template_env = Managoat.Runtimes.Template.setup_env()
    env = Enum.reject(sprite_env, fn {k, _v} -> List.keymember?(template_env, k, 0) end)

    Fountain.Telemetry.span(
      [:setup_script],
      %{conv_id: conv_id, script_size: byte_size(script)},
      fn ->
        :ok = SetupOutput.step(:setup_script)
        publish_stage(conv_id, "setup", "started")

        case exec_streamed(handle, conv_id, "setup", "fountain-setup", script,
               env: env ++ template_env,
               prelude: Managoat.Runtimes.Template.prepare_script(),
               timeout: Map.get(environment, :setup_timeout_seconds, 120) * 1000
             ) do
          {{:ok, 0}, _tail} ->
            publish_stage(conv_id, "setup", "done", %{exit_code: 0})
            {:ok, %{outcome: :ok, exit_code: 0}}

          # The end of what it printed travels with the exit code, as a
          # package step's does, for a workspace's redacted `error`; records
          # that are not redacted drop it (`Provision.reason_text/1`).
          {{:ok, code}, tail} ->
            publish_stage(conv_id, "setup", "failed", %{exit_code: code})
            {{:error, {:setup_exit, code, tail}}, %{outcome: :failed, exit_code: code}}

          {{:error, reason}, _tail} ->
            publish_stage(conv_id, "setup", "failed", %{reason: inspect(reason)})
            {{:error, {:setup_unreachable, reason}}, %{outcome: :failed, reason: inspect(reason)}}
        end
      end
    )
  end

  # Run `script` under `@stream_wrapper`, writing its output to the
  # conversation's log as `output` events of `stage` while it runs. An adapter
  # that streams hands each chunk to the `:on_output` sink, in this process,
  # from inside its exec; one that does not returns it all at exit, and that
  # is written then, as one event. Answers the exec's `{:ok, code}` or
  # `{:error, reason}`, beside the end of what the script printed.
  #
  # The sink is a closure the adapter calls back, so the line buffer between
  # calls lives in this process's dictionary under a key of its own.
  #
  # `:prelude` is shell run in the same exec before the script starts.
  defp exec_streamed(handle, conv_id, stage, name, script, opts) do
    key = {__MODULE__, :stage_output, make_ref()}
    Process.put(key, StageOutput.new(conv_id, stage))

    # An explicit workspace's setup is collected too (#3009), as it arrives.
    sink = fn chunk ->
      :ok = SetupOutput.output(chunk)
      Process.put(key, StageOutput.feed(Process.get(key), chunk))
    end

    {prelude, opts} = Keyword.pop(opts, :prelude, "")

    result =
      Sandbox.exec(
        handle,
        "bash",
        ["-c", prelude <> stream_wrapper(), name, script],
        [stderr_to_stdout: true, on_output: sink] ++ opts
      )

    output = Process.delete(key)

    output =
      case result do
        {:ok, rest, _code} ->
          :ok = SetupOutput.output(rest)
          StageOutput.feed(output, rest)

        {:error, _reason} ->
          output
      end
      |> StageOutput.finish()

    :ok = SetupOutput.flush()

    case result do
      {:ok, _rest, code} -> {{:ok, code}, StageOutput.tail(output)}
      {:error, reason} -> {{:error, reason}, StageOutput.tail(output)}
    end
  end

  # The runtime's own config files, under the conversation's config home
  # `home` (`Fountain.Conversations.ConfigHome.home/1`).
  def write_runtime_config(handle, runtime_module, agent, home) do
    Managoat.Runtimes.write_config(runtime_module, handle, agent, home)
  end

  # The agent's `system` prompt, into the runtime's user-level instructions
  # file under the conversation's config home (#848). Best-effort: a sandbox
  # that refuses the write still runs, on the CLI's default persona, and says
  # so in the log.
  def write_instructions(handle, runtime, agent, home) do
    case Managoat.Runtimes.Instructions.write(handle, runtime, agent, home) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not write agent instructions for #{inspect(agent && agent.name)} (#{runtime}): #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  The runtime's own sandbox preparation, after its ACP adapter is in place.
  `conv` is the conversation (its owner, config home and working directory)
  and `source` its resolved inference source: a codex spawn on a ChatGPT
  subscription gets its `auth.json` from Fountain
  (`CodexChatGPT.prepare_sandbox/5`, ADR 0070) instead of the library's
  API-key write.
  """
  def prepare_runtime_sprite(handle, conv, runtime, runtime_module, agent, sprite_env, source) do
    with :ok <- prepare_acp_adapter(handle, runtime, sprite_env) do
      prepare_runtime_sandbox(handle, conv, runtime, runtime_module, agent, sprite_env, source)
    end
  end

  @doc """
  The second half of `prepare_runtime_sprite/7`, for a caller that has
  already installed the adapter: the conversation's working directory
  (`ConfigHome.ensure/2`), then the runtime's own files (a codex
  `auth.json`, from the API key or from a ChatGPT grant) under its config
  home. A fresh provision installs the adapter early, beside the packages,
  and runs this once the setup script and the inference reservation are
  done, so a clone can still land in the working directory and the files
  Fountain writes for the runtime still land after anything the setup script
  wrote.
  """
  def prepare_runtime_sandbox(handle, conv, runtime, runtime_module, agent, sprite_env, source) do
    home = Fountain.Conversations.ConfigHome.home(conv)

    with :ok <- Fountain.Conversations.ConfigHome.ensure(handle, conv) do
      case Fountain.Conversations.CodexChatGPT.prepare_sandbox(
             handle,
             runtime,
             source,
             conv.user_id,
             home
           ) do
        :skip ->
          Managoat.Runtimes.prepare_sandbox(runtime_module, handle, agent, sprite_env, home)

        result ->
          result
      end
    end
  end

  # Check the pin before opening a fresh connection on a persistent sandbox.
  # Cold provisioning still installs directly. Use the runtime's env (including its
  # broker proxy) for registry access; never relax the sandbox network policy.
  # Keyed on the conversation's runtime, matching the spawn decision.
  def check_acp_adapter(handle, runtime, sprite_env) do
    Fountain.RuntimeDispatch.ensure_installed(handle, runtime, sprite_env)
  end

  def preload_acp_adapter(handle, runtime) do
    Fountain.RuntimeDispatch.preload(handle, runtime)
  end

  def prepare_acp_adapter(handle, runtime, sprite_env) do
    Fountain.RuntimeDispatch.install(handle, runtime, sprite_env)
  end

  # A machine-level step run with no conversation (`Fountain.Machines.Setup`,
  # ADR 0097) has no stream to publish its stages or output to.
  defp publish_stage(conv_id, stage, status, meta \\ %{})
  defp publish_stage(nil, _stage, _status, _meta), do: :ok

  defp publish_stage(conv_id, stage, status, meta),
    do: Conversations.publish_stage(conv_id, stage, status, meta)

  # Stamp the output with the stage that was active when it was emitted
  # so the LiveView (and any API consumer) can group output under its
  # owning stage without inferring it from event interleaving. The clone
  # step's, which arrives whole once a clone is over; `exec_streamed/6` is
  # what writes the packages and setup stages' as it arrives.
  defp log_output(nil, _stage, _output), do: :ok

  defp log_output(conv_id, stage, output) when is_binary(output) and output != "" do
    Conversations.log!(%{
      conversation_id: conv_id,
      kind: "output",
      stream: "stdout",
      stage: stage,
      data: output
    })
    |> tap(fn ev ->
      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, ev})
    end)
  end

  defp log_output(_conv_id, _stage, _), do: :ok
end
