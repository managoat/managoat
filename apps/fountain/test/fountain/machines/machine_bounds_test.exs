defmodule Fountain.Machines.MachineBoundsTest do
  @moduledoc """
  The three timeouts a destroy sits between, pinned at their **defaults**
  (ADR 0058 stage 5).

  `destroy_test.exs` drives the wait with a short bound injected by the test,
  which proves the mechanism and pins no number. These are the numbers every
  production call site actually runs with — none of the three passes
  `:busy_wait_ms` — and the ordering between them is a
  correctness property, not a preference:

      Destroy.busy_wait_ms  <  Machine.destroy_timeout_ms  <  conversation_call_timeout_ms
             5s                        20s                            30s

  Read right to left. A `ConversationServer`'s client gives up at
  `conversation_call_timeout_ms` and answers `{:error, :provisioning}` — a word
  that means the opposite of what a terminate was doing — so anything the
  server does inside one `handle_call` has to finish inside that. The owner's
  call timeout has to be under it for the same reason, and over the protocol's
  own wait, or a destroy that waits its full wait races the timeout and a
  success is reported as a failure. And the protocol's wait has to be the
  smallest, because on the dead-server path it runs in the web request itself.

  There is no lease TTL in any of these since ADR 0072: a lease is held for as
  long as its holder process lives. The wait bounds the *waiter*, and it was
  once the same number as the holder's TTL. That conflation is what made a
  `DELETE` hang for a minute.

  ## And the two a park sits between (stage 6b)

      Park.busy_wait_ms  <  Machine.park_timeout_ms
            5s                      60s

  A park's ceiling is **not** `conversation_call_timeout_ms`, and that is the
  one thing about this row worth saying twice: neither caller is a request.
  The conversation server's park runs inside the server itself, from its own
  `:lifecycle_check` message, so no client of `call_server/2` is waiting on it;
  the reaper's runs in an Oban job.
  """

  use ExUnit.Case, async: true

  alias Fountain.Conversations.ProvisionWatchdog
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Park
  alias Fountain.Machines.Provision
  alias Fountain.Machines.Reads
  alias Fountain.Machines.Resume

  # The ceiling `ConversationServer.call_server/2` reads. Duplicated rather than
  # imported because the point is to pin the relationship to *that* number, and
  # a test that read it through the same default would agree with itself.
  @conversation_call_timeout_ms 30_000

  test "the caller-facing bounds are ordered, with real headroom between them" do
    assert Destroy.busy_wait_ms() == 5_000
    assert Machine.destroy_timeout_ms() == 20_000

    assert Destroy.busy_wait_ms() < Machine.destroy_timeout_ms(),
           "a destroy that waits its own bound would race the owner's call timeout, " <>
             "and a completed destroy would be reported to its caller as a failure"

    assert Machine.destroy_timeout_ms() < @conversation_call_timeout_ms,
           "a ConversationServer's client gives up at #{@conversation_call_timeout_ms}ms " <>
             "with {:error, :provisioning}; a destroy must answer before that"

    # Not decoration: 200ms of scheduling slack between two timeouts is what
    # made the first draft's 60s/60s pair race.
    assert Machine.destroy_timeout_ms() - Destroy.busy_wait_ms() >= 5_000
    assert @conversation_call_timeout_ms - Machine.destroy_timeout_ms() >= 5_000
  end

  test "a park's bounds are ordered, and are not the destroy's" do
    assert Park.busy_wait_ms() == 5_000
    assert Machine.park_timeout_ms() == 60_000

    assert Park.busy_wait_ms() < Machine.park_timeout_ms(),
           "a park that waits its own bound would race the owner's call timeout, and a " <>
             "completed park would be reported to its caller as a failure"

    assert Park.busy_wait_ms() == Destroy.busy_wait_ms(),
           "the two protocols make a caller wait different amounts for the same condition"
  end

  test "background wakes wait through readiness and provider startup" do
    assert Resume.busy_wait_ms() == Destroy.busy_wait_ms()
    assert Machine.resume_timeout_ms() >= Resume.busy_wait_ms() + 30_000 + 60_000 + 25_000
    assert Machine.resume_timeout_ms() > @conversation_call_timeout_ms
  end

  test "a park's call timeout is deliberately over the ConversationServer client ceiling" do
    # Not an oversight and not an ordering to fix. `park_sandbox/2` runs inside
    # the server, reached from its own `:lifecycle_check`, so nothing is
    # waiting at `conversation_call_timeout_ms` for it to answer — and a park
    # that had to finish inside 30s would give up on a slow home checkpoint and
    # destroy the machine instead. A destroy is the one that runs on a request
    # process, which is why it has the tighter ceiling.
    assert Machine.park_timeout_ms() > @conversation_call_timeout_ms
    assert Machine.destroy_timeout_ms() < @conversation_call_timeout_ms
  end

  test "the application default for the conversation call timeout is what this pins against" do
    assert Application.get_env(:fountain, :conversation_call_timeout_ms, 30_000) ==
             @conversation_call_timeout_ms
  end

  test "a provision's ladder, and what bounds it" do
    # A provision is the one operation here that legitimately runs for minutes.
    # Its lease is held for as long as its server lives; what bounds it is
    # `ProvisionWatchdog.deadline_ms/0`, which supersedes the lease and stops
    # the server.
    assert Provision.busy_wait_ms() == Destroy.busy_wait_ms()

    # There is no `Machine.provision_timeout_ms/0` and there is not meant to be:
    # the bracket runs inline on its caller whichever way the gate is set, so
    # there is no `GenServer.call` to put a ceiling on. See
    # `Fountain.Machines.Provision`'s moduledoc.
    #
    # `Code.ensure_loaded!/1` first, because `function_exported?/3` answers
    # `false` for an unloaded module and an `alias` does not load one — so
    # without it this test passed for the wrong reason, and only happened to be
    # safe because a *different* file adds `Mimic.copy(Machine)` (round 1,
    # behaviour review).
    Code.ensure_loaded!(Machine)
    assert function_exported?(Machine, :provision, 3), "the scan below proves nothing"
    refute function_exported?(Machine, :provision_timeout_ms, 0)

    # And the watchdog's own wait for a lease another owner holds, which is the
    # one override in `lib/`: longer than the protocol's, because this caller
    # has waited half an hour already.
    assert ProvisionWatchdog.retire_wait_ms() > Provision.busy_wait_ms()
  end

  # The two bound-shaped calls `lib/` makes on purpose, each spelled exactly as
  # the file makes it. The scan below removes these strings from every file's
  # content before it looks, so a file is never exempt — only the one call is.
  #
  # Stage 7b exempted `provision_watchdog.ex` wholesale and pinned it with a
  # "passes a named accessor" assertion beside it. Stripping the call rather
  # than the file makes the containment pin redundant: an entry here that no
  # file makes any more strips nothing, and the day that call becomes a literal
  # the scan names it.
  @known_good_bound_calls [
    # `ProvisionWatchdog` waits longer than five seconds for a lease it has
    # already waited half an hour for; giving up early would leave a stuck
    # server alive with a live row, the #394 ordering inverted. Pinned by value
    # in "a provision's ladder" above.
    "busy_wait_ms: @retire_wait_ms",
    # A server rebuilding its workspace's lost machine waits for another
    # conversation's rebuild of the same workspace, which holds the lease for
    # a whole provision, rather than standing down and dropping its prompt
    # (ADR 0097 step 4, `Conversations.Rebuild`). Pinned under the provision
    # deadline below.
    "busy_wait_ms: follow_wait_ms()",
    # An explicit workspace's provision on create, at its deadline, retires
    # its machine with the watchdog's own wait and for the watchdog's reason
    # (ADR 0097 step 5, `Workspaces.Provisioner`): the same accessor, so the
    # value pinned above is the one it runs with.
    "busy_wait_ms: ProvisionWatchdog.retire_wait_ms()",
    # A retry of a failed workspace's setup (#3013) waits for a prompt's
    # rebuild of the same workspace as long as that prompt's co-tenants would
    # (`Workspaces.Provisioner.rerun/3`), then follows it: the rebuild's own
    # accessor, pinned under the provision deadline below.
    "busy_wait_ms: Rebuild.follow_wait_ms()"
  ]

  test "a rebuild's wait for the workspace sits inside the provision deadline" do
    assert Fountain.Conversations.Rebuild.follow_wait_ms() >
             Fountain.Machines.Provision.busy_wait_ms()

    assert Fountain.Conversations.Rebuild.follow_wait_ms() <
             Fountain.Conversations.ProvisionWatchdog.deadline_ms(),
           "a server waiting out a co-tenant's rebuild would be killed by its own watchdog"
  end

  # A bound passed as an option, in any of the spellings a protocol takes.
  #
  # `admit_timeout_ms` joined in stage 8a round 1: it is the test seam for the
  # owner-side deadline on an admission, and a `lib/` caller passing it would
  # replace `Machine.admit_timeout_ms/0` for that call with nothing noticing.
  #
  # `attach_timeout_ms`, `detach_timeout_ms` and `resume_timeout_ms` joined in
  # stage 8b, each the test seam for the deadline its owner message carries.
  @bound_option ~r/\b(busy_wait_ms|admit_timeout_ms|attach_timeout_ms|detach_timeout_ms|resume_timeout_ms|read_window_ms):/

  test "an admission's ladder, and why it has no lease to sit under" do
    # An admission is one transaction that may first wait out a live lease, so
    # it has a waiter's bound and a call timeout, and they take the destroy's
    # numbers for the destroy's reasons: the caller is a request (the prompt's
    # `handle_call`), so the ceiling sits under the client's.
    assert Admission.busy_wait_ms() == Destroy.busy_wait_ms()
    assert Machine.admit_timeout_ms() == Machine.destroy_timeout_ms()

    assert Admission.busy_wait_ms() < Machine.admit_timeout_ms(),
           "a caller that gives up before the protocol's own wait would report a refusal " <>
             "that has not happened yet"

    assert Machine.admit_timeout_ms() < @conversation_call_timeout_ms,
           "a ConversationServer's client gives up at #{@conversation_call_timeout_ms}ms; an " <>
             "admission must answer before that"

    assert Machine.admit_timeout_ms() - Admission.busy_wait_ms() >= 5_000
    assert @conversation_call_timeout_ms - Machine.admit_timeout_ms() >= 5_000

    # An admission takes no lease of its own; see `Fountain.Machines.Admission`.
    Code.ensure_loaded!(Admission)
    assert function_exported?(Admission, :busy_wait_ms, 0), "the refutation below proves nothing"
  end

  test "the binding's ladders (stage 8b)" do
    # A detach waits out a live lease first, for `Binding.busy_wait_ms/0`, and
    # sits above that wait the way a destroy sits above its own.
    assert Machine.detach_timeout_ms() == Machine.destroy_timeout_ms()
    assert Binding.busy_wait_ms() == Destroy.busy_wait_ms()

    assert Binding.busy_wait_ms() < Machine.detach_timeout_ms(),
           "a caller that gives up before the protocol's own wait would report a refusal " <>
             "that has not happened yet"

    assert Machine.detach_timeout_ms() - Binding.busy_wait_ms() >= 5_000
    assert Machine.detach_timeout_ms() < @conversation_call_timeout_ms
  end

  test "a read's window, and the one caller ceiling it can overrun (#2394)" do
    # The window has to hold the whole exec: the files API's 30 s timeout, with
    # the margin the hard cutoff keeps before the database expiry a drain reads.
    assert Reads.window_ms() - Reads.margin_ms() >= Fountain.SandboxFiles.exec_timeout_ms(),
           "a read could be cut off before its own exec timeout, turning a slow git " <>
             "status into a 503 the API never used to give"

    # What this does NOT fit under, said here rather than found: a destroy's
    # caller gives up at `destroy_timeout_ms`, and a drain of a read stuck at
    # the provider until its cutoff is longer than that. The caller then reads
    # `:sandbox_unavailable` for a destroy that goes on to finish in the owner
    # — `destroying` is durable and the late message is idempotent (`serve/3`).
    # Only a read that is itself stuck costs this; an ordinary read is gone in
    # well under a second. Pinned so a change to either number is a decision.
    assert Reads.window_ms() > Machine.destroy_timeout_ms()
  end

  test "no call site overrides the bounds" do
    # The defaults only mean something if nothing in `lib/` passes its own. A
    # test may (and `destroy_test.exs` does) — that is the mechanism check.
    #
    # Five levels to the repository root from this directory. The first draft
    # climbed four, landed on `apps/`, found neither candidate directory, and
    # scanned nothing at all — a test that passed because it looked at zero
    # files. Hence the reach assertion below: an empty scan is the failure
    # mode this check has, so it has to be the loud one.
    root = Path.expand("../../../../..", __DIR__)

    files =
      ([Path.join(root, "apps/fountain/lib")] ++
         Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))

    # Not a bare count: the files that could plausibly override a bound are the
    # sites that call a protocol, so the scan has to be shown to reach *them* —
    # and, since stage 8a, the protocol modules themselves, which used to be
    # excluded and now are not. A count alone drifts; this fails the day one of
    # them moves, which is the day to check the scan still covers its new home.
    relative = MapSet.new(files, &Path.relative_to(&1, root))

    for site <- [
          "apps/fountain/lib/fountain/conversations/termination.ex",
          "apps/fountain/lib/fountain/conversations/lifecycle.ex",
          "apps/fountain/lib/fountain/conversations/conversation_server.ex",
          "apps/fountain/lib/fountain/conversations/provision_watchdog.ex",
          "apps/fountain/lib/fountain/conversations/fresh_provision.ex",
          "apps/fountain/lib/fountain/workers/sandbox_reaper.ex",
          "apps/fountain/lib/fountain/machines/machine.ex",
          "apps/fountain/lib/fountain/machines/destroy.ex",
          "apps/fountain/lib/fountain/machines/park.ex",
          "apps/fountain/lib/fountain/machines/resume.ex",
          "apps/fountain/lib/fountain/machines/provision.ex",
          "apps/fountain/lib/fountain/machines/admission.ex",
          "apps/fountain/lib/fountain/machines/binding.ex",
          "apps/fountain/lib/fountain/machines/reads.ex",
          "apps/fountain/lib/fountain/sandbox_files.ex"
        ] do
      assert MapSet.member?(relative, site),
             "the scan missed #{site} (#{length(files)} files under #{root}), so an " <>
               "override there would not be seen and this test proves nothing"
    end

    offenders =
      Enum.filter(files, fn file ->
        file |> File.read!() |> strip_known_good_calls() |> String.match?(@bound_option)
      end)

    assert offenders == [],
           "these pass their own bound, so the defaults above stop being the live " <>
             "numbers: #{inspect(Enum.map(offenders, &Path.relative_to(&1, root)))}"
  end

  # The scan's own positive control: the strip has to remove the call it names
  # and nothing else, or a broken strip would either hide a literal or flag the
  # known-good file for ever.
  test "the strip removes exactly the known-good call" do
    planted = """
    Machine.fail_provision(id, busy_wait_ms: @retire_wait_ms, actor: "x")
    """

    refute planted |> strip_known_good_calls() |> String.match?(@bound_option)

    # A literal beside the named call, in a file the old scan exempted.
    assert (planted <> "    busy_wait_ms: 1_000\n")
           |> strip_known_good_calls()
           |> String.match?(@bound_option)

    # And a literal in the position the named call occupies.
    assert "busy_wait_ms: 1_800_000" |> strip_known_good_calls() |> String.match?(@bound_option)
  end

  defp strip_known_good_calls(content) do
    Enum.reduce(@known_good_bound_calls, content, &String.replace(&2, &1, ""))
  end
end
