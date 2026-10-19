defmodule Fountain.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      # Kept in lockstep with the newest v* git tag — release-bump.yml
      # computes the next tag from this value.
      version: "0.38.0",
      hex: [
        ignore_advisories: [
          # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
          # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "EEF-CVE-2026-43969",
          # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
          # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "EEF-CVE-2026-43971",
          # cowlib 2.19.0 is already the newest Hex release, OSV lists no fixed
          # Hex version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "EEF-CVE-2026-43966",
          # gun 2.5.0 is already the newest Hex release, OSV lists no fixed Hex
          # version, and Fountain serves HTTP with Bandit rather than Cowboy.
          "GHSA-w4f7-4cxr-rv3c"
        ]
      ],
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      # Built-in cover rather than ExCoveralls (#620): ExCoveralls has no way
      # to merge results from separate machines, and the suite is now run as
      # six partitions in six CI jobs, each of which instruments every
      # module while exercising a sixth of the tests. `mix test --partitions`
      # exports a .coverdata per partition and `mix test.coverage` merges them
      # here, at the umbrella root, where the 85% threshold is enforced once
      # against the union. Dropping the threshold per partition instead would
      # have deleted the gate while leaving it looking present.
      test_coverage: coverage(),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        # A fixed path (rather than the _build default) so CI can cache the
        # PLT across runs — cold PLT builds on a runner take minutes.
        #
        # list_unused_filters is deliberately NOT set: dialyxir has failed to
        # credit string-form filters as used, which would fail the run.
        # Audit the ignore file by hand with `mix dialyzer --list-unused-filters`
        # (tuple entries report accurately) when trimming it.
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        # :mix so Mix.Task-based code (`mix openapi.spec.json`, the aliases)
        # analyzes cleanly — without it every Mix.* call is "unknown function".
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test
      ]
    ]
  end

  # Shared with apps/fountain/mix.exs — see coverage.exs for why it is a file.
  defp coverage do
    Path.expand("coverage.exs", __DIR__) |> Code.eval_file() |> elem(0)
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      fountain_server: [
        applications: [fountain: :permanent],
        steps: [:assemble, &copy_acp_bundles/1]
      ]
    ]
  end

  # The pinned ACP adapter bundles ship in the release (#2970, ADR 0092), so a
  # provision never waits on GitHub. `mix acp.bundles` fetches each from its
  # release tag into a cache under _build/ (which dev reads directly) and
  # checks it against the size and SHA-512 compiled into
  # Managoat.Runtimes.ACP; a release copies the cache into the app's priv/.
  # A bundle that cannot be fetched or does not verify fails the build.
  @acp_bundle_cache Path.expand("_build/acp-bundles", __DIR__)

  defp acp_bundles(_args) do
    Mix.Task.run("compile")
    fetch_acp_bundles()
  end

  defp copy_acp_bundles(release) do
    vsn = release.applications[:fountain][:vsn]

    dest =
      Path.join([release.path, "lib", "fountain-#{vsn}", "priv", "runtimes", "acp", "bundles"])

    File.mkdir_p!(dest)

    for path <- fetch_acp_bundles() do
      File.cp!(path, Path.join(dest, Path.basename(path)))
    end

    release
  end

  defp fetch_acp_bundles do
    {:ok, _} = Application.ensure_all_started(:req)
    File.mkdir_p!(@acp_bundle_cache)

    for {_runtime, bundle} <- Managoat.Runtimes.ACP.bundles() do
      path = Path.join(@acp_bundle_cache, bundle.file)

      unless File.regular?(path) and acp_bundle_verified?(File.read!(path), bundle) do
        Mix.shell().info("Fetching #{bundle.url}")

        bytes =
          Req.get!(bundle.url, raw: true, receive_timeout: 60_000, redirect_log_level: false).body

        acp_bundle_verified?(bytes, bundle) ||
          Mix.raise("#{bundle.file} does not match its pinned size and SHA-512")

        File.write!(path <> ".part", bytes)
        File.rename!(path <> ".part", path)
      end

      path
    end
  end

  defp acp_bundle_verified?(bytes, bundle) do
    byte_size(bytes) == bundle.bytes and
      "sha512-" <> Base.encode64(:crypto.hash(:sha512, bytes)) == bundle.integrity
  end

  defp aliases do
    [
      setup: ["deps.get", "acp.bundles", "ecto.setup"],
      "acp.bundles": [&acp_bundles/1],
      # `cmd` under `do --app`, rather than `do --app <task>` directly (#1526,
      # replacing the deprecated `cmd --app`): `mix do --app` narrows only a
      # task that is `@recursive`, and none of ecto.create, ecto.drop,
      # ecto.migrate, ecto.rollback or run is one. Handed the task directly,
      # `do --app fountain ecto.create` drops the narrowing and runs at the
      # umbrella root, and `do --app fountain run priv/repo/seeds.exs` fails
      # outright ("No such file"), because the relative path resolves against
      # the root. `mix cmd` IS recursive, so the --app narrows *it* and the
      # command runs inside apps/fountain, which is what `cmd --app` did.
      "ecto.setup": [
        "do --app fountain cmd mix ecto.create",
        "do --app fountain cmd mix ecto.migrate",
        "do --app fountain cmd mix run priv/repo/seeds.exs"
      ],
      "ecto.reset": ["do --app fountain cmd mix ecto.drop", "ecto.setup"],
      # Render the served OpenAPI spec to dist/openapi.json, which
      # scripts/sdk-contract/generate.py turns into the SDK's generated types.
      "openapi.export": [
        "openapi.spec.json --spec FountainWeb.ApiSpec --vendor-extensions=false dist/openapi.json"
      ],
      # The gate is scripts/precommit.sh, one OS process per stage, and its
      # exit status is the verdict. `System.halt/1` rather than `Mix.raise/1`
      # so that status reaches the shell untouched: nothing in Mix's own exit
      # path, and no at_exit handler, sits between the failed stage and `$?`.
      precommit: [&precommit/1]
    ]
  end

  defp precommit(args) do
    case Mix.shell().cmd(Enum.join(["scripts/precommit.sh" | args], " ")) do
      0 -> :ok
      status -> System.halt(status)
    end
  end
end
