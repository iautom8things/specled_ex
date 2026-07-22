defmodule SpecLedEx.Evidence.Sync do
  @moduledoc """
  Reconciles the local and remote `spec-evidence` refs using Git plumbing.

  Reconciliation is a union of tree entries, not a history merge. Conflicting
  entry paths use the same run-stamp ordering as local evidence writes, so
  independently-created orphan roots converge deterministically.
  """

  alias SpecLedEx.Evidence.{Entry, Git}

  @local_ref "refs/heads/spec-evidence"
  @remote_ref "refs/remotes/origin/spec-evidence"
  @remote_head "refs/heads/spec-evidence"
  @max_attempts 3
  @zero String.duplicate("0", 40)

  @type result :: %{
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          attempts: pos_integer(),
          action: :adopted | :noop | :pushed
        }

  @doc """
  Fetches the remote evidence ref and returns its fetched commit, or `:absent`.
  """
  @spec fetch(Path.t(), keyword()) :: {:ok, String.t() | :absent} | {:error, term()}
  def fetch(root, opts \\ []) do
    remote = Keyword.get(opts, :remote, "origin")
    remote_ref = remote_tracking_ref(remote)

    case Git.run(root, [
           "fetch",
           remote,
           "+#{@remote_head}:#{remote_ref}"
         ]) do
      {:ok, _output} ->
        ref_commit(root, remote_ref)

      {:error, {:git, _args, output, _status}} = error ->
        if remote_absent?(output) do
          _ = Git.run(root, ["update-ref", "-d", remote_ref])
          {:ok, :absent}
        else
          error
        end
    end
  end

  @doc """
  Reconciles and pushes evidence, retrying lease races at most three times.

  `:keep` may be a `MapSet` of tree hashes; when present, entries outside that
  set are removed after each fetched union. This is used only by explicit
  pruning. `:before_push` is a test seam called immediately before each push.
  """
  @spec run(Path.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(root, opts \\ []) do
    run_attempt(root, opts, 1, nil)
  end

  defp run_attempt(_root, _opts, attempt, last_error) when attempt > @max_attempts do
    {:error, {:sync_exhausted, last_error}}
  end

  defp run_attempt(root, opts, attempt, _last_error) do
    remote = Keyword.get(opts, :remote, "origin")

    with {:ok, remote_commit} <- fetch(root, remote: remote),
         {:ok, local_commit} <- ref_commit(root, @local_ref),
         {:ok, local_entries} <- entries(root, local_commit),
         {:ok, remote_entries} <- entries(root, remote_commit) do
      drift = drift(local_entries, remote_entries)

      reconcile(root, local_commit, remote_commit, local_entries, remote_entries, opts)
      |> push_result(root, remote, remote_commit, drift, opts, attempt)
    end
  end

  defp reconcile(_root, :absent, :absent, _local, _remote, _opts), do: {:noop, :absent}

  defp reconcile(root, :absent, remote, local_entries, remote_entries, opts) do
    if is_struct(opts[:keep], MapSet) do
      reconcile_entries(root, :absent, remote, local_entries, remote_entries, opts)
    else
      {:adopt, remote}
    end
  end

  defp reconcile(root, local, local, local_entries, remote_entries, opts) do
    if is_struct(opts[:keep], MapSet) do
      reconcile_entries(root, local, local, local_entries, remote_entries, opts)
    else
      {:noop, local}
    end
  end

  defp reconcile(root, local, remote, local_entries, remote_entries, opts) do
    reconcile_entries(root, local, remote, local_entries, remote_entries, opts)
  end

  defp reconcile_entries(root, local, remote, local_entries, remote_entries, opts) do
    merged_entries =
      local_entries
      |> Map.merge(remote_entries, fn _path, local_entry, remote_entry ->
        Entry.latest(local_entry, remote_entry)
      end)
      |> keep_entries(Keyword.get(opts, :keep))

    with {:ok, tree} <- write_tree(root, merged_entries),
         {:ok, commit} <- commit_tree(root, tree, local, remote),
         :ok <- update_local_ref(root, commit, local) do
      {:push, commit}
    end
  end

  defp push_result({:noop, _commit}, _root, _remote, _fetched, drift, _opts, attempt) do
    {:ok, Map.merge(drift, %{attempts: attempt, action: :noop})}
  end

  defp push_result({:adopt, commit}, root, _remote, _fetched, drift, _opts, attempt) do
    case update_local_ref(root, commit, :absent) do
      :ok -> {:ok, Map.merge(drift, %{attempts: attempt, action: :adopted})}
      {:cas_failed, reason} -> {:error, {:local_ref_changed, reason}}
      error -> error
    end
  end

  defp push_result({:push, _commit}, root, remote, fetched, drift, opts, attempt) do
    with :ok <- call_before_push(opts[:before_push], root, attempt, fetched),
         :ok <- push(root, remote, fetched) do
      {:ok, Map.merge(drift, %{attempts: attempt, action: :pushed})}
    else
      {:retry, reason} ->
        sleep(opts, attempt)
        run_attempt(root, opts, attempt + 1, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_result({:cas_failed, reason}, root, _remote, _fetched, _drift, opts, attempt) do
    sleep(opts, attempt)
    run_attempt(root, opts, attempt + 1, {:local_ref_changed, reason})
  end

  defp push_result({:error, reason}, _root, _remote, _fetched, _drift, _opts, _attempt),
    do: {:error, reason}

  defp push(root, remote, :absent) do
    case Git.run(root, ["push", remote, "#{@local_ref}:#{@remote_head}"]) do
      {:ok, _} ->
        :ok

      {:error, {:git, _args, output, _status}} = error ->
        if push_race?(output), do: {:retry, error}, else: error
    end
  end

  defp push(root, remote, fetched) do
    case Git.run(root, [
           "push",
           "--force-with-lease=#{@remote_head}:#{fetched}",
           remote,
           "#{@local_ref}:#{@remote_head}"
         ]) do
      {:ok, _} ->
        :ok

      {:error, {:git, _args, output, _status}} = error ->
        if push_race?(output), do: {:retry, error}, else: error
    end
  end

  defp entries(_root, :absent), do: {:ok, %{}}

  defp entries(root, commit) do
    with {:ok, output} <- Git.run(root, ["ls-tree", "-r", "--name-only", commit]) do
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
        with true <- Entry.valid_filename?(path),
             {:ok, json} <- Git.run(root, ["cat-file", "-p", "#{commit}:#{path}"]),
             {:ok, entry} <- Entry.decode_file(path, json) do
          {:cont, {:ok, Map.put(acc, path, entry)}}
        else
          false -> {:halt, {:error, {:invalid_evidence_path, path}}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp keep_entries(entries, nil), do: entries

  defp keep_entries(entries, %MapSet{} = keep) do
    Map.filter(entries, fn {path, _entry} ->
      MapSet.member?(keep, Path.rootname(path, ".json"))
    end)
  end

  defp drift(local, remote) do
    local_paths = local |> Map.keys() |> MapSet.new()
    remote_paths = remote |> Map.keys() |> MapSet.new()

    %{
      ahead: local_paths |> MapSet.difference(remote_paths) |> MapSet.size(),
      behind: remote_paths |> MapSet.difference(local_paths) |> MapSet.size()
    }
  end

  defp write_tree(root, entries) do
    with {:ok, index_path} <- Git.temp_path(root, "sync-index"),
         result <- write_tree_with_index(root, index_path, entries) do
      File.rm(index_path)
      result
    end
  end

  defp write_tree_with_index(root, index_path, entries) do
    Enum.reduce_while(entries, :ok, fn {path, entry}, :ok ->
      with {:ok, blob} <- hash_entry(root, entry),
           {:ok, _} <-
             Git.run(root, ["update-index", "--add", "--cacheinfo", "100644,#{blob},#{path}"],
               env: [{"GIT_INDEX_FILE", index_path}]
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok ->
        case Git.run(root, ["write-tree"], env: [{"GIT_INDEX_FILE", index_path}]) do
          {:ok, tree} -> {:ok, String.trim(tree)}
          error -> error
        end

      error ->
        error
    end
  end

  defp hash_entry(root, entry) do
    with {:ok, path} <- Git.temp_path(root, "sync-entry.json"),
         :ok <- File.write(path, Entry.encode!(entry)) do
      result =
        case Git.run(root, ["hash-object", "-w", path]) do
          {:ok, blob} -> {:ok, String.trim(blob)}
          error -> error
        end

      File.rm(path)
      result
    end
  end

  defp commit_tree(root, tree, local, :absent) do
    commit_tree_command(root, ["commit-tree", tree, "-p", local, "-m", "sync spec evidence"])
  end

  defp commit_tree(root, tree, :absent, remote) do
    commit_tree_command(root, ["commit-tree", tree, "-p", remote, "-m", "prune spec evidence"])
  end

  defp commit_tree(root, tree, local, local) do
    commit_tree_command(root, ["commit-tree", tree, "-p", local, "-m", "prune spec evidence"])
  end

  defp commit_tree(root, tree, local, remote) do
    commit_tree_command(root, [
      "commit-tree",
      tree,
      "-p",
      local,
      "-p",
      remote,
      "-m",
      "sync spec evidence"
    ])
  end

  defp commit_tree_command(root, args) do
    case Git.run(root, args) do
      {:ok, commit} -> {:ok, String.trim(commit)}
      error -> error
    end
  end

  defp update_local_ref(root, commit, expected) do
    old = if expected == :absent, do: @zero, else: expected

    case Git.run(root, ["update-ref", @local_ref, commit, old]) do
      {:ok, _} ->
        :ok

      {:error, {:git, ["update-ref" | _], output, _status}} ->
        {:cas_failed, String.trim(output)}

      error ->
        error
    end
  end

  defp ref_commit(root, ref) do
    case Git.run(root, ["rev-parse", "--verify", "--quiet", ref]) do
      {:ok, commit} -> {:ok, String.trim(commit)}
      {:error, _} -> {:ok, :absent}
    end
  end

  defp call_before_push(nil, _root, _attempt, _fetched), do: :ok

  defp call_before_push(fun, root, attempt, fetched) when is_function(fun, 3),
    do: fun.(root, attempt, fetched)

  defp sleep(opts, attempt) do
    sleep_fun = Keyword.get(opts, :sleep, &Process.sleep/1)
    base = 250 * attempt
    jitter = :rand.uniform(base) - div(base, 2)
    sleep_fun.(max(base + jitter, 0))
  end

  defp remote_tracking_ref("origin"), do: @remote_ref
  defp remote_tracking_ref(remote), do: "refs/remotes/#{remote}/spec-evidence"

  defp remote_absent?(output) do
    String.contains?(output, "couldn't find remote ref") or
      String.contains?(output, "could not find remote ref")
  end

  defp push_race?(output) do
    String.contains?(output, "stale info") or
      String.contains?(output, "fetch first") or
      String.contains?(output, "non-fast-forward") or
      String.contains?(output, "rejected")
  end
end
