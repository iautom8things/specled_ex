defmodule SpecLedEx.Evidence.Store do
  @moduledoc """
  Local plumbing-only evidence store backed by `refs/heads/spec-evidence`.
  """

  alias SpecLedEx.Evidence.{Entry, Git}

  @ref "refs/heads/spec-evidence"
  @max_attempts 5
  @zero String.duplicate("0", 40)

  @type warning :: %{code: String.t(), message: String.t()}

  @doc """
  Reads an evidence entry by tree hash from the local evidence ref.
  """
  @spec read(Path.t(), String.t()) :: {:ok, map()} | :absent | {:error, term()}
  def read(root, tree_hash) when is_binary(tree_hash) do
    filename = "#{tree_hash}.json"

    with true <- Entry.valid_filename?(filename),
         {:ok, _commit} <- current_commit(root),
         {:ok, json} <- Git.run(root, ["cat-file", "-p", "#{@ref}:#{filename}"]),
         {:ok, entry} <- Entry.decode_file(filename, json) do
      {:ok, entry}
    else
      false -> {:error, :invalid_tree_hash}
      :absent -> :absent
      {:error, {:git, ["cat-file" | _], _output, _status}} -> :absent
      error -> error
    end
  end

  @doc """
  Records an evidence entry with bounded local compare-and-swap retries.
  """
  @spec record(Path.t(), map(), keyword()) :: :ok | {:warning, warning()}
  def record(root, entry, opts \\ []) when is_map(entry) do
    case record_attempt(root, entry, opts, 1) do
      :ok ->
        :ok

      {:error, reason} ->
        {:warning,
         %{
           code: "evidence/local_write_failed",
           message: "evidence/local_write_failed: #{inspect(reason)}"
         }}
    end
  end

  defp record_attempt(_root, _entry, _opts, attempt) when attempt > @max_attempts do
    {:error, :cas_exhausted}
  end

  defp record_attempt(root, entry, opts, attempt) do
    expected = current_commit(root)

    with {:ok, tree} <- build_tree(root, expected, entry),
         {:ok, commit} <- commit_tree(root, tree, expected),
         :ok <- maybe_call_hook(opts[:before_update], root, entry, attempt),
         :ok <- update_ref(root, commit, expected) do
      :ok
    else
      :cas_failed ->
        sleep(attempt)
        record_attempt(root, entry, opts, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_tree(root, expected, entry) do
    with {:ok, index_path} <- Git.temp_path(root, "evidence-index"),
         result <- build_tree_with_index(root, index_path, expected, entry) do
      File.rm(index_path)
      result
    end
  end

  defp build_tree_with_index(root, index_path, expected, entry) do
    with :ok <- seed_tree(root, index_path, expected),
         {:ok, existing} <- existing_entry(root, expected, entry["tree_hash"]),
         winner <- Entry.latest(existing, entry),
         {:ok, blob} <- hash_entry(root, winner),
         {:ok, _} <-
           Git.run(
             root,
             [
               "update-index",
               "--add",
               "--cacheinfo",
               "100644,#{blob},#{winner["tree_hash"]}.json"
             ],
             env: [{"GIT_INDEX_FILE", index_path}]
           ),
         {:ok, tree} <- Git.run(root, ["write-tree"], env: [{"GIT_INDEX_FILE", index_path}]) do
      {:ok, String.trim(tree)}
    end
  end

  defp current_commit(root) do
    case Git.run(root, ["rev-parse", "--verify", "--quiet", @ref]) do
      {:ok, commit} -> {:ok, String.trim(commit)}
      {:error, _} -> :absent
    end
  end

  defp existing_entry(_root, :absent, _tree_hash), do: {:ok, nil}

  defp existing_entry(root, {:ok, _commit}, tree_hash) do
    case read(root, tree_hash) do
      {:ok, entry} -> {:ok, entry}
      :absent -> {:ok, nil}
      error -> error
    end
  end

  defp seed_tree(_root, _index_path, :absent), do: :ok

  defp seed_tree(root, index_path, {:ok, commit}) do
    case Git.run(root, ["read-tree", "#{commit}^{tree}"], env: [{"GIT_INDEX_FILE", index_path}]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp hash_entry(root, entry) do
    with {:ok, path} <- temp_blob_path(root),
         :ok <- File.write(path, Entry.encode!(entry)) do
      result =
        case Git.run(root, ["hash-object", "-w", path]) do
          {:ok, output} -> {:ok, String.trim(output)}
          error -> error
        end

      File.rm(path)
      result
    end
  end

  defp commit_tree(root, tree, :absent) do
    case Git.run(root, ["commit-tree", tree, "-m", "spec evidence"]) do
      {:ok, commit} -> {:ok, String.trim(commit)}
      error -> error
    end
  end

  defp commit_tree(root, tree, {:ok, parent}) do
    case Git.run(root, ["commit-tree", tree, "-p", parent, "-m", "spec evidence"]) do
      {:ok, commit} -> {:ok, String.trim(commit)}
      error -> error
    end
  end

  defp update_ref(root, commit, expected) do
    old = if expected == :absent, do: @zero, else: elem(expected, 1)

    case Git.run(root, ["update-ref", @ref, commit, old]) do
      {:ok, _} -> :ok
      {:error, {:git, ["update-ref" | _], _output, _status}} -> :cas_failed
      error -> error
    end
  end

  defp temp_blob_path(root) do
    case Git.temp_path(root, "evidence-blob") do
      {:ok, path} -> {:ok, path <> ".json"}
      error -> error
    end
  end

  defp maybe_call_hook(nil, _root, _entry, _attempt), do: :ok

  defp maybe_call_hook(fun, root, entry, attempt) when is_function(fun, 3),
    do: fun.(root, entry, attempt)

  defp sleep(attempt) do
    base = 50 * attempt
    jitter = :rand.uniform(base) - div(base, 2)
    Process.sleep(max(base + jitter, 0))
  end
end
