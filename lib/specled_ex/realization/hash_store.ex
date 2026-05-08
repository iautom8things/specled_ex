defmodule SpecLedEx.Realization.HashStore do
  @moduledoc """
  Committed-hash persistence for realization tiers.

  Writes are atomic: `.spec/state.json.tmp` is fully written and fsynced, then
  renamed into place. A crash mid-write leaves the previously committed state
  intact — partial writes are not a reachable state.

  Every stored entry carries a `hasher_version` (the current value of
  `@hasher_version` inside this module). When a read encounters an older
  `hasher_version`, the store rehashes the affected entries silently (a debug
  log names the rehash) and persists the updated state. No user-visible finding
  is produced — per `specled.binding.hasher_version_internal`, the hasher
  version is an internal attribute, not a user-config key.
  """

  require Logger

  alias SpecLedEx.Realization.Canonical

  @hasher_version 1
  @state_rel Path.join(".spec", "state.json")
  @realization_key "realization"

  @doc "Returns the current hasher version."
  @spec hasher_version() :: pos_integer()
  def hasher_version, do: @hasher_version

  @doc """
  Reads committed realization hashes from `root`'s `.spec/state.json`.

  Returns a map of tier → MFA → %{"hash" => base16_hash, "hasher_version" => int}.
  If any entry carries an older `hasher_version`, the entry is transparently
  dropped from the returned map; callers re-compute hashes and call `write/2`
  with the new values. The original state.json is left unchanged on read; the
  rehash becomes visible only after the caller writes updated hashes.

  The `rehash` option (function) can be supplied to perform inline rehashing
  during the read — the function receives `(tier, mfa, old_entry)` and must
  return either `{:ok, new_hash_binary}` or `:drop`. When supplied, rehashed
  entries are persisted back before the read returns.
  """
  @spec read(Path.t(), keyword()) :: %{optional(String.t()) => %{optional(String.t()) => map()}}
  def read(root, opts \\ []) do
    path = state_path(root)

    case File.read(path) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, %{} = decoded} ->
            realization = Map.get(decoded, @realization_key, %{})
            {live, stale} = split_by_version(realization)

            if stale != %{} do
              Logger.debug(fn ->
                "SpecLedEx.HashStore: silent rehash triggered for " <>
                  "#{count_entries(stale)} entries (hasher_version < #{@hasher_version})"
              end)

              rehash_fun = Keyword.get(opts, :rehash)
              merged = maybe_apply_rehash(live, stale, rehash_fun)
              if rehash_fun, do: write(root, merged)
              merged
            else
              live
            end

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Deep-merges `seed` per-tier entries into the existing realization map and
  atomically rewrites `<root>/.spec/state.json`.

  Unlike `write/2` (which replaces the entire realization section), `merge/2`
  preserves non-seeded tier entries: for each tier in `seed`, the seed's
  entries are merged on top of the existing tier's entries; tiers absent from
  `seed` are left untouched. Same-key collisions resolve to the seed value
  (the seeding caller already computed the current hash).

  Entries lacking a `"hasher_version"` are stamped with the current
  `@hasher_version` via `ensure_version/1`. Non-realization top-level sections
  in state.json are preserved.

  Used by the orchestrator's silent-seed pass for newly-tracked entries.
  `write/2` keeps its existing replacement semantics for the post-run
  `refresh_and_commit_hashes/3` path.
  """
  @spec merge(Path.t(), map()) :: :ok
  def merge(root, seed) when is_map(seed) do
    path = state_path(root)
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    {existing_top, existing_realization} = read_top_and_realization(path)

    stamped_seed =
      Map.new(seed, fn {tier, entries} ->
        stamped_entries =
          Map.new(entries, fn {mfa, entry} -> {mfa, ensure_version(entry)} end)

        {tier, stamped_entries}
      end)

    merged_realization =
      Enum.reduce(stamped_seed, existing_realization, fn {tier, entries}, acc ->
        Map.update(acc, tier, entries, fn current -> Map.merge(current, entries) end)
      end)

    payload =
      existing_top
      |> Map.put(@realization_key, merged_realization)
      |> Jason.encode!(pretty: true)

    write_atomic(tmp, path, payload)
    :ok
  end

  @doc """
  Writes the realization hash map atomically.

  Writes to `<path>.tmp`, fsyncs the tmp file, then renames over the target.
  The previous committed state is left intact on crash.
  """
  @spec write(Path.t(), map()) :: :ok
  def write(root, realization) when is_map(realization) do
    path = state_path(root)
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    existing =
      case File.read(path) do
        {:ok, binary} ->
          case Jason.decode(binary) do
            {:ok, %{} = decoded} -> decoded
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end

    stamped =
      Map.new(realization, fn {tier, entries} ->
        stamped_entries =
          Map.new(entries, fn {mfa, entry} -> {mfa, ensure_version(entry)} end)

        {tier, stamped_entries}
      end)

    payload =
      existing
      |> Map.put(@realization_key, stamped)
      |> Jason.encode!(pretty: true)

    write_atomic(tmp, path, payload)
    :ok
  end

  @doc "Convenience: returns the stored hash for a tier+MFA or `nil`."
  @spec fetch(map(), String.t(), String.t()) :: binary() | nil
  def fetch(realization, tier, mfa) when is_map(realization) do
    with %{} = entries <- Map.get(realization, tier),
         %{"hash" => hash} <- Map.get(entries, mfa) do
      case Base.decode16(hash, case: :mixed) do
        {:ok, bytes} -> bytes
        :error -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Computes a hash entry (hex-encoded + current version) ready for `write/2`.
  """
  @spec entry(Macro.t()) :: map()
  def entry(normalized_ast) do
    hash = Canonical.hash(normalized_ast)
    %{"hash" => Base.encode16(hash, case: :lower), "hasher_version" => @hasher_version}
  end

  defp state_path(root), do: Path.join(root, @state_rel)

  defp read_top_and_realization(path) do
    case File.read(path) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, %{} = decoded} ->
            realization = Map.get(decoded, @realization_key, %{})
            realization = if is_map(realization), do: realization, else: %{}
            {decoded, realization}

          _ ->
            {%{}, %{}}
        end

      {:error, _} ->
        {%{}, %{}}
    end
  end

  defp split_by_version(realization) do
    Enum.reduce(realization, {%{}, %{}}, fn {tier, entries}, {live, stale} ->
      {live_entries, stale_entries} =
        Enum.reduce(entries, {%{}, %{}}, fn {mfa, entry}, {l, s} ->
          version = Map.get(entry, "hasher_version", 0)

          if version == @hasher_version do
            {Map.put(l, mfa, entry), s}
          else
            {l, Map.put(s, mfa, entry)}
          end
        end)

      live = if live_entries == %{}, do: live, else: Map.put(live, tier, live_entries)
      stale = if stale_entries == %{}, do: stale, else: Map.put(stale, tier, stale_entries)
      {live, stale}
    end)
  end

  defp count_entries(map) do
    Enum.reduce(map, 0, fn {_tier, entries}, acc -> acc + map_size(entries) end)
  end

  defp maybe_apply_rehash(live, _stale, nil), do: live

  defp maybe_apply_rehash(live, stale, fun) when is_function(fun, 3) do
    Enum.reduce(stale, live, fn {tier, entries}, acc ->
      rehashed =
        Enum.reduce(entries, %{}, fn {mfa, old_entry}, tier_acc ->
          case fun.(tier, mfa, old_entry) do
            {:ok, new_hash_bin} when is_binary(new_hash_bin) ->
              Map.put(tier_acc, mfa, %{
                "hash" => Base.encode16(new_hash_bin, case: :lower),
                "hasher_version" => @hasher_version
              })

            :drop ->
              tier_acc
          end
        end)

      if rehashed == %{} do
        acc
      else
        Map.update(acc, tier, rehashed, &Map.merge(&1, rehashed))
      end
    end)
  end

  defp ensure_version(%{"hasher_version" => _} = entry), do: entry

  defp ensure_version(entry) when is_map(entry),
    do: Map.put(entry, "hasher_version", @hasher_version)

  defp write_atomic(tmp, path, payload) do
    File.write!(tmp, payload)

    case File.open(tmp, [:read, :binary]) do
      {:ok, io} ->
        try do
          :ok = :file.sync(io)
        after
          File.close(io)
        end

      _ ->
        :ok
    end

    File.rename!(tmp, path)
  end
end
