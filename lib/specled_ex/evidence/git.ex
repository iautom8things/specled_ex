defmodule SpecLedEx.Evidence.Git do
  @moduledoc """
  Shared Git plumbing helpers for the evidence store, sync, and tree-hash
  modules: subprocess execution, unique temp-path allocation under the
  repository's `.git/specled-tmp` directory, and random hex generation for
  uniquifying temp filenames.
  """

  @tmp_dir_name "specled-tmp"

  @doc """
  Runs a git plumbing command against `root`, returning `{:ok, output}` or
  `{:error, {:git, args, output, status}}` on non-zero exit.
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {:git, [String.t()], String.t(), non_neg_integer()}}
  def run(root, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])

    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, args, output, status}}
    end
  end

  @doc """
  Lists a tree recursively through one `ls-tree -r -z` subprocess, returning
  each entry as `%{mode:, type:, oid:, path:}`. The `-z` framing keeps paths
  unquoted, so crafted entry names round-trip byte-identical. Optional
  `pathspecs` narrow the listing.
  """
  @spec ls_tree_entries(Path.t(), String.t(), [String.t()]) ::
          {:ok, [%{mode: String.t(), type: String.t(), oid: String.t(), path: String.t()}]}
          | {:error, term()}
  def ls_tree_entries(root, treeish, pathspecs \\ []) do
    args = ["ls-tree", "-r", "-z", treeish] ++ pathspec_args(pathspecs)

    with {:ok, listing} <- run(root, args) do
      listing
      |> :binary.split(<<0>>, [:global, :trim_all])
      |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
        with [meta, path] <- :binary.split(record, "\t"),
             [mode, type, oid] <- String.split(meta, " ", parts: 3) do
          {:cont, {:ok, [%{mode: mode, type: type, oid: oid, path: path} | acc]}}
        else
          _ -> {:halt, {:error, {:unexpected_tree_entry, record}}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp pathspec_args([]), do: []
  defp pathspec_args(pathspecs), do: ["--" | pathspecs]

  @doc """
  Reads many git objects through a single `git cat-file --batch` subprocess.

  Takes a list of object ids (any `rev-parse`-safe names; callers pass blob
  OIDs) and returns their contents in request order. One subprocess handles
  the whole batch, so reading N entries costs one spawn instead of N.

  Any id the object database cannot resolve fails the whole call with
  `{:error, {:missing_object, id}}` — callers request ids they just listed
  from a tree, so a miss signals structural corruption, not a bad entry.
  """
  @spec cat_file_batch(Path.t(), [String.t()], keyword()) ::
          {:ok, [binary()]} | {:error, term()}
  def cat_file_batch(root, ids, opts \\ [])

  def cat_file_batch(_root, [], _opts), do: {:ok, []}

  def cat_file_batch(root, ids, opts) when is_list(ids) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_executable_not_found}

      git ->
        timeout = Keyword.get(opts, :timeout, 60_000)

        port =
          Port.open({:spawn_executable, git}, [
            :binary,
            :exit_status,
            :hide,
            args: ["-C", root, "cat-file", "--batch"]
          ])

        try do
          Port.command(port, Enum.map(ids, &[&1, "\n"]))
          collect_batch(port, length(ids), <<>>, [], timeout)
        after
          close_port(port)
        end
    end
  end

  defp collect_batch(_port, 0, _buffer, acc, _timeout), do: {:ok, Enum.reverse(acc)}

  defp collect_batch(port, remaining, buffer, acc, timeout) do
    case parse_batch_record(buffer) do
      {:entry, content, rest} ->
        collect_batch(port, remaining - 1, rest, [content | acc], timeout)

      {:missing, id} ->
        {:error, {:missing_object, id}}

      {:bad_header, header} ->
        {:error, {:cat_file_batch_bad_header, header}}

      :incomplete ->
        receive do
          {^port, {:data, data}} ->
            collect_batch(port, remaining, buffer <> data, acc, timeout)

          {^port, {:exit_status, status}} ->
            {:error, {:cat_file_batch_exited, status}}
        after
          timeout -> {:error, :cat_file_batch_timeout}
        end
    end
  end

  # `cat-file --batch` answers each request with either
  # `<oid> <type> <size>\n<contents>\n` or `<id> missing\n`.
  defp parse_batch_record(buffer) do
    case :binary.split(buffer, "\n") do
      [_incomplete_header] ->
        :incomplete

      [header, rest] ->
        case String.split(header, " ") do
          [id, "missing"] ->
            {:missing, id}

          [_oid, _type, size] ->
            case Integer.parse(size) do
              {bytes, ""} -> parse_batch_content(header, bytes, rest)
              _ -> {:bad_header, header}
            end

          _ ->
            {:bad_header, header}
        end
    end
  end

  defp parse_batch_content(header, bytes, rest) do
    case rest do
      <<content::binary-size(bytes), "\n", tail::binary>> ->
        {:entry, content, tail}

      _ when byte_size(rest) <= bytes ->
        :incomplete

      _ ->
        {:bad_header, header}
    end
  end

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain_port_messages(port)
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _message} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  @doc """
  Allocates a unique path under the repository's `.git/specled-tmp`
  directory, prefixed with `label`, creating the directory if needed.
  """
  @spec temp_path(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def temp_path(root, label) do
    with {:ok, directory} <- tmp_dir(root) do
      {:ok,
       Path.join(
         directory,
         "#{label}-#{System.unique_integer([:positive, :monotonic])}-#{random_hex(8)}"
       )}
    end
  end

  @doc """
  Generates a random lowercase hex string of `bytes` bytes.
  """
  @spec random_hex(pos_integer()) :: String.t()
  def random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp tmp_dir(root) do
    with {:ok, git_path} <- run(root, ["rev-parse", "--git-path", @tmp_dir_name]) do
      directory = Path.expand(String.trim(git_path), root)

      with :ok <- File.mkdir_p(directory) do
        {:ok, directory}
      end
    end
  end
end
