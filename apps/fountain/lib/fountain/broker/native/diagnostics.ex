defmodule Fountain.Broker.Native.Diagnostics do
  @moduledoc """
  A warning for a CONNECT tunnel whose transfer has stalled.

  The broker's observer samples each tunnel once per `stall_ms/0`
  (`Native.listener_spec/0`), so a stalled tunnel warns at most that often. Only a
  sample that shows a stall is logged: a request still pending while the
  origin has sent nothing, or a client write still blocked, for at least
  `stall_ms/0`. Healthy connections write nothing. IDs stay in logs, never in
  Prometheus labels; the terminal request log remains the egress record.
  """

  require Logger

  @handler "fountain-broker-native-diagnostics"
  @stall_ms 30_000

  @doc "How long a pending transfer must be idle or blocked to count as stalled."
  def stall_ms, do: @stall_ms

  @doc false
  def attach do
    case :telemetry.attach(@handler, [:managoat, :broker, :diagnostic], &__MODULE__.handle/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle(_event, measurements, %{event: :progress} = meta, _config) do
    pending = Map.get(measurements, :pending_requests, 0)
    idle = ms(Map.get(measurements, :upstream_idle, Map.get(measurements, :duration)))
    blocked = ms(Map.get(measurements, :client_write_in_flight))

    if pending > 0 and (idle >= @stall_ms or blocked >= @stall_ms) do
      owner =
        case get_in(meta, [:meta, "workspace_id"]) do
          workspace when is_binary(workspace) -> "workspace #{workspace}"
          _ -> "conv #{get_in(meta, [:meta, "conversation_id"]) || "?"}"
        end

      # No URL, path, headers, body, raw error or wholesale session metadata.
      Logger.warning(
        "broker: stalled transfer #{owner} connection #{meta.connection_id} " <>
          "host #{meta.host}:#{meta.port} pending #{pending} upstream_idle_ms #{idle} " <>
          "client_write_blocked_ms #{blocked} upstream_bytes #{Map.get(measurements, :upstream_bytes, 0)}"
      )
    end

    :ok
  rescue
    _ ->
      # A malformed event must not detach the handler or disclose its contents.
      :ok
  end

  def handle(_event, _measurements, _meta, _config), do: :ok

  defp ms(value) when is_integer(value),
    do: System.convert_time_unit(value, :native, :millisecond)

  defp ms(_), do: 0
end
