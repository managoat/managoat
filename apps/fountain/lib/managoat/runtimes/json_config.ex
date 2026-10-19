defmodule Managoat.Runtimes.JsonConfig do
  @moduledoc """
  The JSON config files Managoat writes keys into, in a conversation's config
  home, while keeping the rest of each file: claude's `settings.json` and
  `.claude.json`, gemini's `settings.json` (`Managoat.Runtimes.Layout.merged_files/1`).

  A file is read, the keys Managoat owns are put over what is there, and the
  result is written beside the file under a name of this call's own and
  renamed into place, so a CLI reading it never sees half a file and two
  writers never move each other's temporary file. A file that already
  carries those values is left alone: a wake that changes nothing does not
  race a CLI writing its own state into the same file.

  What else a file holds is kept: the CLI's own state, and whatever the
  runtime template put there (#2998), such as a template's hooks in claude's
  `settings.json`. A file that is there but is not a JSON object (a CLI
  halfway through its own write) is read once more, then is an error rather
  than something to overwrite.
  """

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Retry

  # Each path on a line: `-` for a file that is not there, `+<base64>` for
  # one that is. Base64, so a file's bytes cannot be mistaken for the frame.
  @read_script ~S"""
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '+'
      base64 -w0 -- "$p" || exit 1
      printf '\n'
    else
      printf -- '-\n'
    fi
  done
  """

  @doc """
  Read `paths` from the sandbox in one exec. Answers each path's JSON object,
  or nil for a path that is not there. A file that is not a JSON object is
  read once more, after a moment, then is
  `{:error, {:runtime_config, path, :unreadable}}`.
  """
  @spec read(Sandbox.Handle.t(), [String.t()]) ::
          {:ok, %{String.t() => map() | nil}} | {:error, term()}
  def read(handle, [_ | _] = paths), do: read(handle, paths, 1)

  defp read(handle, paths, attempt) do
    case exec_retrying(handle, ["-c", @read_script, "managoat-json-read" | paths], hd(paths)) do
      {:ok, out} ->
        case decode_all(paths, out) do
          {:error, {:runtime_config, _, :unreadable}} when attempt == 1 ->
            Process.sleep(200)
            read(handle, paths, 2)

          decoded ->
            decoded
        end

      {:error, _} = error ->
        error
    end
  end

  defp decode_all(paths, out) do
    lines = String.split(to_string(out), "\n", trim: true)

    if length(lines) == length(paths) do
      paths
      |> Enum.zip(lines)
      |> Enum.reduce_while({:ok, %{}}, fn {path, line}, {:ok, acc} ->
        case decode_line(line) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, path, value)}}
          :error -> {:halt, {:error, {:runtime_config, path, :unreadable}}}
        end
      end)
    else
      {:error, {:runtime_config, hd(paths), :unreadable}}
    end
  end

  defp decode_line("-"), do: {:ok, nil}

  defp decode_line("+" <> encoded) do
    with {:ok, text} <- Base.decode64(encoded), do: decode_object(text)
  end

  defp decode_line(_line), do: :error

  @doc """
  Decode `text` as a JSON object. An empty file is the empty object, as a
  file nobody has written to yet would be.
  """
  @spec decode_object(String.t()) :: {:ok, map()} | :error
  def decode_object(text) do
    if String.trim(text) == "" do
      {:ok, %{}}
    else
      case Jason.decode(text) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> :error
      end
    end
  end

  @doc """
  Put `keys` over `current` (what `read/2` answered for `path`) and write the
  result to `path` by temporary file and rename, mode `mode`. Nothing is
  written when the file is there and already carries every one of `keys`.
  """
  @spec put(Sandbox.Handle.t(), String.t(), map() | nil, map(), non_neg_integer()) ::
          :ok | {:error, term()}
  def put(handle, path, current, keys, mode \\ 0o600) when is_map(keys) do
    if is_map(current) and Map.merge(current, keys) == current do
      :ok
    else
      write(handle, path, Map.merge(current || %{}, keys), mode)
    end
  end

  @doc """
  Write `map` to `path` by temporary file and rename, mode `mode`. The
  temporary name is this call's own, and the rename succeeds when it finds
  its file already moved: a retried exec whose first reply was lost has done
  its work.
  """
  @spec write(Sandbox.Handle.t(), String.t(), map(), non_neg_integer()) :: :ok | {:error, term()}
  def write(handle, path, map, mode \\ 0o600) when is_map(map) do
    tmp = path <> ".managoat." <> Integer.to_string(System.unique_integer([:positive])) <> ".tmp"
    body = Jason.encode!(map, pretty: true)

    case Retry.with_backoff(fn -> Sandbox.write_file(handle, tmp, body, mode: mode) end,
           label: "config write #{path}"
         ) do
      :ok ->
        case exec_retrying(handle, ["-c", rename_script(tmp, path)], path) do
          {:ok, _out} -> :ok
          {:error, _} = error -> error
        end

      {:error, reason} ->
        {:error, {:runtime_config, path, reason}}
    end
  end

  @doc false
  def rename_script(tmp, path) do
    "if [ -e #{quote_shell(tmp)} ]; then mv -f -- #{quote_shell(tmp)} #{quote_shell(path)}; " <>
      "else [ -f #{quote_shell(path)} ]; fi"
  end

  defp exec_retrying(handle, args, path) do
    case Retry.with_backoff(
           fn -> Sandbox.exec(handle, "bash", args, timeout: 15_000) end,
           label: "config #{path}"
         ) do
      {:ok, out, 0} -> {:ok, to_string(out)}
      {:ok, _out, code} -> {:error, {:runtime_config, path, {:exit, code}}}
      {:error, reason} -> {:error, {:runtime_config, path, reason}}
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
