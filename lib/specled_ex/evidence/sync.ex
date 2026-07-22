defmodule SpecLedEx.Evidence.Sync do
  @moduledoc """
  Reconciles the local and remote `spec-evidence` refs using Git plumbing.

  Reconciliation is a union of tree entries, not a history merge. Conflicting
  entry paths use the same run-stamp ordering as local evidence writes, so
  independently-created orphan roots converge deterministically.

  A single entry this build cannot validate never halts reconciliation for
  every peer. A blob it cannot decode (invalid filename, malformed JSON, or
  a schema version it does not recognize) is quarantined — carried through
  the union byte-identical under its original path — and reported as a
  warning. A non-blob tree entry is carried through opaquely at the tree
  level (original mode and object id), and an entry at a path git refuses
  to stage is dropped from the union so the store self-heals; both are
  reported as warnings. Only git-level failures of the tree listing or
  object database halt.

  When the fetched remote commit already equals the local commit and no
  explicit `:keep` was supplied, `run/2` short-circuits before reading a
  single entry: no `ls-tree`, no `cat-file`, no decode on either ref. This
  keeps the pre-push hook's near-universal outcome (nothing changed since
  the last sync) O(1) in store size instead of O(entries).

  When real reconciliation does happen (local and remote refs differ) and
  the merged entry count crosses `@auto_prune_entry_threshold`, sync folds
  in the same reachable-tree-hash keep-set `mix spec.prune` computes and
  applies it before writing and pushing the merged tree, so the store stops
  growing without bound even when nobody runs `mix spec.prune` by hand. A
  failure to compute the keep-set — including the reachability floor: a
  keep-set that is empty or would filter a non-empty store down to nothing
  — degrades to a plain (unpruned) sync with a warning rather than failing
  the attempt.
  """

  alias SpecLedEx.Evidence.{Entry, Git}

  @local_ref "refs/heads/spec-evidence"
  @remote_ref "refs/remotes/origin/spec-evidence"
  @remote_head "refs/heads/spec-evidence"
  @max_attempts 3
  @auto_prune_entry_threshold 500
  @zero String.duplicate("0", 40)

  @type warning :: %{code: String.t(), message: String.t()}

  @type result :: %{
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          attempts: pos_integer(),
          action: :adopted | :noop | :pushed,
          warnings: [warning()]
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
  Computes the reachable-tree-hash keep-set: tree hashes of commits reachable
  from local branch heads and remote-tracking refs (excluding `spec-evidence`
  refs themselves), after the caller has fetched. Shared by `mix spec.prune`'s
  explicit invocation and `run/2`'s automatic size-threshold pruning.

  An empty computation is a reachability-floor violation, not a valid
  keep-set: a checkout with no non-evidence refs (detached or ref-less CI
  checkouts) would otherwise "prune" every entry and force-push a wiped
  store to every peer. It returns `{:error, :empty_keep_set}` instead, so
  explicit pruning refuses and auto-prune degrades to an unpruned sync.
  """
  @spec reachable_keep_set(Path.t()) :: {:ok, MapSet.t()} | {:error, term()}
  def reachable_keep_set(root) do
    with {:ok, refs_output} <-
           Git.run(root, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"]) do
      refs =
        refs_output
        |> String.split("\n", trim: true)
        |> Enum.reject(&evidence_ref?/1)

      case refs do
        [] ->
          {:error, :empty_keep_set}

        refs ->
          case Git.run(root, ["log", "--format=%T" | refs]) do
            {:ok, output} ->
              case String.split(output, "\n", trim: true) do
                [] -> {:error, :empty_keep_set}
                tree_hashes -> {:ok, MapSet.new(tree_hashes)}
              end

            error ->
              error
          end
      end
    end
  end

  @doc """
  Reconciles and pushes evidence, retrying lease races at most three times.

  `:keep` may be a `MapSet` of tree hashes; when present, entries outside that
  set are removed after each fetched union. This is set explicitly by
  pruning, and computed automatically (see the moduledoc) once the merged
  entry count crosses the auto-prune size threshold. `:auto_prune_threshold`
  overrides that threshold (default `#{@auto_prune_entry_threshold}`, mainly
  for tests). `:before_push` is a test seam called immediately before each
  push.

  The result's `:warnings` list carries one entry per quarantined path
  encountered on either side of this attempt. It is empty when the no-op
  short circuit applies, since no entry is read in that case.
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
         {:ok, local_commit} <- ref_commit(root, @local_ref) do
      if local_commit == remote_commit and not is_struct(Keyword.get(opts, :keep), MapSet) do
        {:ok, %{ahead: 0, behind: 0, attempts: attempt, action: :noop, warnings: []}}
      else
        reconcile_attempt(root, opts, attempt, remote, local_commit, remote_commit)
      end
    end
  end

  defp reconcile_attempt(root, opts, attempt, remote, local_commit, remote_commit) do
    with {:ok, local_entries, local_warnings} <- entries(root, local_commit),
         {:ok, remote_entries, remote_warnings} <- entries(root, remote_commit) do
      drift = drift(local_entries, remote_entries)

      {action, keep_warnings} =
        reconcile(root, local_commit, remote_commit, local_entries, remote_entries, opts)

      warnings = local_warnings ++ remote_warnings ++ keep_warnings

      push_result(action, root, remote, remote_commit, drift, warnings, opts, attempt)
    end
  end

  defp reconcile(_root, :absent, :absent, _local, _remote, _opts), do: {{:noop, :absent}, []}

  defp reconcile(root, :absent, remote, local_entries, remote_entries, opts) do
    if is_struct(opts[:keep], MapSet) do
      reconcile_entries(root, :absent, remote, local_entries, remote_entries, opts)
    else
      {{:adopt, remote}, []}
    end
  end

  defp reconcile(root, local, local, local_entries, remote_entries, opts) do
    if is_struct(opts[:keep], MapSet) do
      reconcile_entries(root, local, local, local_entries, remote_entries, opts)
    else
      {{:noop, local}, []}
    end
  end

  defp reconcile(root, local, remote, local_entries, remote_entries, opts) do
    reconcile_entries(root, local, remote, local_entries, remote_entries, opts)
  end

  defp reconcile_entries(root, local, remote, local_entries, remote_entries, opts) do
    merged = Map.merge(local_entries, remote_entries, &merge_entry/3)

    case apply_keep(root, merged, opts) do
      {:ok, merged_entries, keep_warnings} ->
        action =
          with {:ok, tree} <- write_tree(root, merged_entries),
               {:ok, commit} <- commit_tree(root, tree, local, remote),
               :ok <- update_local_ref(root, commit, local) do
            {:push, commit}
          end

        {action, keep_warnings}

      {:error, reason} ->
        {{:error, reason}, []}
    end
  end

  # An explicit `:keep` (from `mix spec.prune`) always wins. Otherwise, once
  # the merged entry count crosses the auto-prune threshold, sync folds in
  # the same reachable-tree-hash keep-set `mix spec.prune` computes.
  #
  # The reachability floor guards the OUTCOME, not just the computation: a
  # keep-set that filters a non-empty store down to nothing — whether the
  # set was empty or merely disjoint from every stored key (a checkout
  # whose refs reach none of the evidenced trees) — must not wipe every
  # peer's evidence. Explicit pruning fails the attempt so `mix spec.prune`
  # can refuse; auto-prune degrades to an unpruned sync with a warning,
  # since it is housekeeping, never a correctness gate.
  defp apply_keep(root, merged, opts) do
    case Keyword.get(opts, :keep) do
      %MapSet{} = keep ->
        kept = keep_entries(merged, keep)

        if wipes_store?(merged, kept) do
          {:error, :keep_set_would_wipe_store}
        else
          {:ok, kept, []}
        end

      nil ->
        threshold = Keyword.get(opts, :auto_prune_threshold, @auto_prune_entry_threshold)

        if map_size(merged) > threshold do
          auto_prune(root, merged)
        else
          {:ok, merged, []}
        end
    end
  end

  defp auto_prune(root, merged) do
    case reachable_keep_set(root) do
      {:ok, keep} ->
        kept = keep_entries(merged, keep)

        if wipes_store?(merged, kept) do
          {:ok, merged, [auto_prune_degraded_warning(:keep_set_would_wipe_store)]}
        else
          {:ok, kept, []}
        end

      {:error, reason} ->
        {:ok, merged, [auto_prune_degraded_warning(reason)]}
    end
  end

  defp wipes_store?(merged, kept), do: map_size(kept) == 0 and map_size(merged) > 0

  defp auto_prune_degraded_warning(reason) do
    %{
      code: "evidence/auto_prune_degraded",
      message:
        "evidence/auto_prune_degraded: keep-set computation failed " <>
          "(#{inspect(reason)}); synced without pruning"
    }
  end

  defp merge_entry(_path, {:known, local_entry}, {:known, remote_entry}) do
    {:known, Entry.latest(local_entry, remote_entry)}
  end

  defp merge_entry(_path, {:known, _} = local_entry, {:raw, _}), do: local_entry
  defp merge_entry(_path, {:raw, _}, {:known, _} = remote_entry), do: remote_entry

  defp merge_entry(_path, {:raw, local_raw}, {:raw, remote_raw}) do
    {:raw, Enum.max([local_raw, remote_raw])}
  end

  defp merge_entry(_path, {:opaque, _, _} = local_opaque, {:opaque, _, _} = remote_opaque) do
    Enum.max([local_opaque, remote_opaque])
  end

  defp merge_entry(_path, {:opaque, _, _}, remote_entry), do: remote_entry
  defp merge_entry(_path, local_entry, {:opaque, _, _}), do: local_entry

  defp push_result({:noop, _commit}, _root, _remote, _fetched, drift, warnings, _opts, attempt) do
    {:ok, Map.merge(drift, %{attempts: attempt, action: :noop, warnings: warnings})}
  end

  defp push_result({:adopt, commit}, root, _remote, _fetched, drift, warnings, _opts, attempt) do
    case update_local_ref(root, commit, :absent) do
      :ok -> {:ok, Map.merge(drift, %{attempts: attempt, action: :adopted, warnings: warnings})}
      {:cas_failed, reason} -> {:error, {:local_ref_changed, reason}}
      error -> error
    end
  end

  defp push_result({:push, _commit}, root, remote, fetched, drift, warnings, opts, attempt) do
    with :ok <- call_before_push(opts[:before_push], root, attempt, fetched),
         :ok <- push(root, remote, fetched) do
      {:ok, Map.merge(drift, %{attempts: attempt, action: :pushed, warnings: warnings})}
    else
      {:retry, reason} ->
        sleep(opts, attempt)
        run_attempt(root, opts, attempt + 1, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_result(
         {:cas_failed, reason},
         root,
         _remote,
         _fetched,
         _drift,
         _warnings,
         opts,
         attempt
       ) do
    sleep(opts, attempt)
    run_attempt(root, opts, attempt + 1, {:local_ref_changed, reason})
  end

  defp push_result(
         {:error, reason},
         _root,
         _remote,
         _fetched,
         _drift,
         _warnings,
         _opts,
         _attempt
       ),
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

  # Reads a ref's entries with a constant number of subprocesses: one
  # `ls-tree -r -z` for the listing and one `cat-file --batch` for every
  # blob, instead of one `cat-file` spawn per entry.
  #
  # Tolerance extends to the tree layer, not just blob contents: a non-blob
  # entry (a crafted gitlink) is carried through the union byte-identical at
  # the tree level as `{:opaque, mode, oid}` with one warning, and an entry
  # at a path git refuses to stage (`..`, `.git`, and friends) is dropped
  # from the union with one warning — so the store self-heals on the next
  # push instead of wedging reconciliation for every peer. Only a genuine
  # git-level failure (unlistable tree, unreadable object database) halts,
  # since that signals a structural problem rather than a single bad entry.
  defp entries(_root, :absent), do: {:ok, %{}, []}

  defp entries(root, commit) do
    with {:ok, listing} <- Git.run(root, ["ls-tree", "-r", "-z", commit]),
         {:ok, tree_entries} <- parse_tree_listing(listing) do
      {unsafe, stageable} = Enum.split_with(tree_entries, &unsafe_path?(&1.path))
      {opaque, blobs} = Enum.split_with(stageable, &(&1.type != "blob"))

      with {:ok, contents} <- Git.cat_file_batch(root, Enum.map(blobs, & &1.oid)) do
        acc = Map.new(opaque, fn entry -> {entry.path, {:opaque, entry.mode, entry.oid}} end)

        tree_warnings =
          Enum.map(unsafe, &skipped_warning(&1.path)) ++
            Enum.map(opaque, &quarantine_warning(&1.path, :non_blob_entry))

        {acc, blob_warnings} =
          blobs
          |> Enum.zip(contents)
          |> Enum.reduce({acc, []}, fn {%{path: path}, content}, {acc, warnings} ->
            case classify_entry(path, content) do
              {:ok, entry} ->
                {Map.put(acc, path, {:known, entry}), warnings}

              {:quarantine, raw, reason} ->
                {Map.put(acc, path, {:raw, raw}), [quarantine_warning(path, reason) | warnings]}
            end
          end)

        {:ok, acc, tree_warnings ++ Enum.reverse(blob_warnings)}
      end
    end
  end

  # Each `ls-tree -r -z` record is `<mode> <type> <oid>\t<path>`,
  # NUL-terminated and unquoted. Only a record that does not parse at all
  # halts; entry-level oddities are classified by the caller.
  defp parse_tree_listing(listing) do
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

  # Mirrors git's own verify_path rejections closely enough to keep every
  # union we write stageable by `update-index`: empty components, `.`,
  # `..`, and `.git` (any case) are refused by git and would otherwise
  # wedge the write for every peer.
  defp unsafe_path?(path) do
    path == "" or String.starts_with?(path, "/") or String.ends_with?(path, "/") or
      Enum.any?(String.split(path, "/"), fn component ->
        component in ["", ".", ".."] or String.downcase(component) == ".git"
      end)
  end

  defp skipped_warning(path) do
    %{
      code: "evidence/entry_skipped",
      message:
        "evidence/entry_skipped: #{inspect(path)}: path is not stageable by git; " <>
          "dropped from the union"
    }
  end

  # A single malformed, unreadable, or unrecognized-schema entry must never
  # halt reconciliation for every peer (an evidence entry never gates). Any
  # entry this build cannot validate is quarantined: carried through the
  # tree union byte-identical under its original path, with one warning.
  defp classify_entry(path, content) do
    if Entry.valid_filename?(path) do
      case Entry.decode_file(path, content) do
        {:ok, entry} -> {:ok, entry}
        {:error, reason} -> {:quarantine, content, reason}
      end
    else
      {:quarantine, content, :invalid_evidence_path}
    end
  end

  defp quarantine_warning(path, reason) do
    %{
      code: "evidence/entry_quarantined",
      message: "evidence/entry_quarantined: #{path}: #{inspect(reason)}"
    }
  end

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

  @hash_object_chunk 200
  @update_index_chunk 200

  defp write_tree(root, entries) do
    with {:ok, index_path} <- Git.temp_path(root, "sync-index"),
         result <- write_tree_with_index(root, index_path, entries) do
      File.rm(index_path)
      result
    end
  end

  # Builds the merged tree with a bounded number of subprocesses: entry
  # blobs are hashed through chunked `hash-object -w` invocations and staged
  # through chunked `update-index --cacheinfo` invocations, instead of two
  # spawns per entry. Chunking keeps each argument list far below ARG_MAX.
  # Opaque (non-blob) entries are staged directly from their listed mode and
  # oid — carried through byte-identical at the tree level, never read.
  defp write_tree_with_index(root, index_path, entries) do
    {opaque_entries, content_entries} =
      Enum.split_with(entries, fn {_path, entry} -> match?({:opaque, _, _}, entry) end)

    opaque_stage =
      Enum.map(opaque_entries, fn {path, {:opaque, mode, oid}} -> {path, mode, oid} end)

    with {:ok, blob_stage} <- hash_entries(root, content_entries),
         :ok <- add_index_entries(root, index_path, opaque_stage ++ blob_stage),
         {:ok, tree} <- Git.run(root, ["write-tree"], env: [{"GIT_INDEX_FILE", index_path}]) do
      {:ok, String.trim(tree)}
    end
  end

  defp hash_entries(root, entries) do
    with {:ok, dir} <- Git.temp_path(root, "sync-entries"),
         :ok <- File.mkdir_p(dir),
         result <- hash_entries_from(root, dir, entries) do
      File.rm_rf(dir)
      result
    end
  end

  defp hash_entries_from(root, dir, entries) do
    files =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {{path, entry}, position} ->
        {path, Path.join(dir, Integer.to_string(position)), entry_content(entry)}
      end)

    with :ok <- write_entry_files(files) do
      files
      |> Enum.chunk_every(@hash_object_chunk)
      |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, pairs} ->
        file_args = Enum.map(chunk, fn {_path, file, _content} -> file end)

        case Git.run(root, ["hash-object", "-w", "--" | file_args]) do
          {:ok, output} ->
            blobs = String.split(output, "\n", trim: true)

            if length(blobs) == length(chunk) do
              paths = Enum.map(chunk, fn {path, _file, _content} -> path end)

              staged =
                Enum.zip_with(paths, blobs, fn path, blob -> {path, "100644", blob} end)

              {:cont, {:ok, pairs ++ staged}}
            else
              {:halt, {:error, {:hash_object_output_mismatch, length(chunk), length(blobs)}}}
            end

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp write_entry_files(files) do
    Enum.reduce_while(files, :ok, fn {_path, file, content}, :ok ->
      case File.write(file, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:entry_write_failed, file, reason}}}
      end
    end)
  end

  defp entry_content({:known, entry}), do: Entry.encode!(entry)
  defp entry_content({:raw, raw}), do: raw

  defp add_index_entries(_root, _index_path, []), do: :ok

  defp add_index_entries(root, index_path, staged_entries) do
    staged_entries
    |> Enum.chunk_every(@update_index_chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      cacheinfo_args =
        Enum.flat_map(chunk, fn {path, mode, oid} -> ["--cacheinfo", "#{mode},#{oid},#{path}"] end)

      case Git.run(root, ["update-index", "--add" | cacheinfo_args],
             env: [{"GIT_INDEX_FILE", index_path}]
           ) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
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

  defp evidence_ref?(ref) do
    ref == @local_ref or String.ends_with?(ref, "/spec-evidence")
  end

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
