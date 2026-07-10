defmodule SpecLedEx.Realization.HashStore do
  @moduledoc """
  Committed-hash persistence for realization tiers.

  The committed realization baseline lives in `.spec/realization_hashes.json`,
  a dedicated committed file whose top level is the tier → MFA → entry map.
  Output is canonicalized (recursively sorted keys) so diffs read as
  subject-level realization changes. `.spec/state.json` carries no baseline —
  it is freely regenerable derived state.

  Writes are atomic: `.spec/realization_hashes.json.tmp` is fully written and
  fsynced, then renamed into place. A crash mid-write leaves the previously
  committed state intact — partial writes are not a reachable state.

  Legacy migration: when `.spec/realization_hashes.json` is absent, reads fall
  back to the `"realization"` key of an existing `.spec/state.json` (where the
  baseline used to be embedded). The first `write/2` or `merge/2` persists to
  the dedicated file; `merge/2` reads through the same fallback so a legacy
  baseline is carried forward rather than dropped.

  Every stored entry carries a `hasher_version` (the current value of
  `@hasher_version` inside this module). When a read encounters an older
  `hasher_version`, the store rehashes the affected entries silently (a debug
  log names the rehash) and persists the updated state. No user-visible finding
  is produced — per `specled.binding.hasher_version_internal`, the hasher
  version is an internal attribute, not a user-config key.
  """

  require Logger

  alias SpecLedEx.Json
  alias SpecLedEx.Realization.Canonical

  @hasher_version 1
  @baseline_rel Path.join(".spec", "realization_hashes.json")
  @state_rel Path.join(".spec", "state.json")
  @realization_key "realization"

  @doc "Returns the current hasher version."
  @spec hasher_version() :: pos_integer()
  def hasher_version, do: @hasher_version

  @doc "Repository-relative path of the committed baseline file."
  @spec baseline_rel() :: Path.t()
  def baseline_rel, do: @baseline_rel

  @doc """
  Reads committed realization hashes from `root`'s
  `.spec/realization_hashes.json`.

  When the dedicated file is absent, falls back to the `"realization"` key of
  `root`'s `.spec/state.json` (the legacy embedded location). A present but
  malformed dedicated file is authoritative and reads as empty — the fallback
  never resurrects a stale embedded baseline once the dedicated file exists.

  Returns a map of tier → MFA → %{"hash" => base16_hash, "hasher_version" => int}.
  If any entry carries an older `hasher_version`, the entry is transparently
  dropped from the returned map; callers re-compute hashes and call `write/2`
  with the new values. The on-disk baseline is left unchanged on read; the
  rehash becomes visible only after the caller writes updated hashes.

  The `rehash` option (function) can be supplied to perform inline rehashing
  during the read — the function receives `(tier, mfa, old_entry)` and must
  return either `{:ok, new_hash_binary}` or `:drop`. When supplied, rehashed
  entries are persisted back before the read returns.
  """
  @spec read(Path.t(), keyword()) :: %{optional(String.t()) => %{optional(String.t()) => map()}}
  def read(root, opts \\ []) do
    realization = read_raw(root)
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
  end

  @doc """
  Deep-merges `seed` per-tier entries into the existing baseline and
  atomically rewrites `<root>/.spec/realization_hashes.json`.

  Unlike `write/2` (which replaces the entire baseline), `merge/2` preserves
  non-seeded entries: for each tier in `seed`, the seed's entries are merged
  on top of the existing tier's entries; tiers absent from `seed` are left
  untouched. Same-key collisions resolve to the seed value (the seeding
  caller already computed the current hash).

  The existing baseline is read through the same legacy fallback chain as
  `read/2`, so merging into a repo whose baseline still lives inside
  `.spec/state.json` migrates the embedded entries into the dedicated file
  rather than dropping them.

  Entries lacking a `"hasher_version"` are stamped with the current
  `@hasher_version` via `ensure_version/1`.

  Used by the orchestrator's silent-seed pass and by the post-run
  `refresh_and_commit_hashes/3` flat-tier refresh, which must merge rather
  than replace so the silent-seeded `implementation` section survives.
  """
  @spec merge(Path.t(), map()) :: :ok
  def merge(root, seed) when is_map(seed) do
    existing = read_raw(root)

    stamped_seed =
      Map.new(seed, fn {tier, entries} ->
        stamped_entries =
          Map.new(entries, fn {mfa, entry} -> {mfa, ensure_version(entry)} end)

        {tier, stamped_entries}
      end)

    merged =
      Enum.reduce(stamped_seed, existing, fn {tier, entries}, acc ->
        Map.update(acc, tier, entries, fn current -> Map.merge(current, entries) end)
      end)

    persist(root, merged)
  end

  @doc """
  Writes the realization hash map atomically, replacing the entire baseline.

  Writes to `.spec/realization_hashes.json.tmp`, fsyncs the tmp file, then
  renames over the target. The previous committed state is left intact on
  crash.
  """
  @spec write(Path.t(), map()) :: :ok
  def write(root, realization) when is_map(realization) do
    stamped =
      Map.new(realization, fn {tier, entries} ->
        stamped_entries =
          Map.new(entries, fn {mfa, entry} -> {mfa, ensure_version(entry)} end)

        {tier, stamped_entries}
      end)

    persist(root, stamped)
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

  defp baseline_path(root), do: Path.join(root, @baseline_rel)

  # Raw (version-unfiltered) baseline. The dedicated file is authoritative
  # whenever it exists; the state.json fallback applies only when it is absent.
  defp read_raw(root) do
    path = baseline_path(root)

    case File.read(path) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, %{} = decoded} -> decoded
          _ -> %{}
        end

      {:error, _} ->
        read_legacy_state(root)
    end
  end

  defp read_legacy_state(root) do
    case File.read(Path.join(root, @state_rel)) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, %{} = decoded} ->
            case Map.get(decoded, @realization_key) do
              %{} = realization -> realization
              _ -> %{}
            end

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp persist(root, realization) do
    path = baseline_path(root)
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    payload =
      realization
      |> Json.encode_to_iodata!()
      |> IO.iodata_to_binary()

    write_atomic(tmp, path, payload)
    :ok
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
