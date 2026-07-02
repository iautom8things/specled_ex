defmodule SpecLedEx.StateJsonFixture do
  @moduledoc """
  Test helpers for driving multi-trajectory committed-baseline fixtures
  (`.spec/realization_hashes.json`; historically embedded in `.spec/state.json`).

  The realization tier-implication work needs to test what `mix spec.check`
  does across four baseline trajectories per binding entry:

    * **cold** — baseline missing entirely (a fresh checkout / first run).
    * **warm** — baseline present, every entry is committed and current.
    * **seeded** — baseline present, the entry under test is missing
      (silent-seed pass should compute and write its hash on this run).
    * **dangling** — baseline present, the entry under test points at
      an MFA or module that cannot be resolved at runtime.

  These helpers compose the trajectory in a tmp `root` without touching the
  project's real `.spec/` files. Pin a tmp root in test setup, then call
  `seed/2` to lay down a starting state and `read/1` or
  `assert_state_contains/3` to inspect it after the system under test has
  run.

  ## Shape

  The realization map is the tier → key → hash shape stored at the top
  level of `.spec/realization_hashes.json`:

      %{
        "api_boundary" => %{
          "Foo.bar/1" => <hash_bin>
        },
        "implementation" => %{
          "MyMod" => <hash_bin>
        }
      }

  Hashes are passed as **raw binaries** (e.g. `:crypto.hash(:sha256, "x")`).
  `seed/2` hex-encodes them and stamps the current
  `SpecLedEx.Realization.HashStore.hasher_version/0` so the resulting
  baseline file matches what `HashStore.write/2` would have produced.

  Keys may be MFA strings (`"Foo.bar/1"`) or bare-module strings
  (`"SpecLedEx.Coverage"`) — the fixture is tier/key-agnostic and stores
  whatever string the caller hands it.

  ## Example

      setup do
        root = Path.join(System.tmp_dir!(), "specled_state_\#{System.unique_integer([:positive])}")
        File.mkdir_p!(root)
        on_exit(fn -> File.rm_rf!(root) end)
        {:ok, root: root}
      end

      test "warm trajectory", %{root: root} do
        StateJsonFixture.seed(root, %{
          "api_boundary" => %{"Foo.bar/1" => :crypto.hash(:sha256, "head-only")}
        })

        StateJsonFixture.assert_state_contains(root, "api_boundary", "Foo.bar/1")
      end
  """

  alias SpecLedEx.Realization.HashStore

  @typedoc "Tier name as it appears in the baseline file (e.g. \"api_boundary\")."
  @type tier :: String.t()

  @typedoc "MFA string (\"Foo.bar/1\") or bare-module string (\"My.Mod\")."
  @type entry_key :: String.t()

  @typedoc "Tier-keyed map of entry → raw hash binary."
  @type seed_map :: %{optional(tier()) => %{optional(entry_key()) => binary()}}

  @typedoc "Tier-keyed map of entry → stored hash entry (decoded from state.json)."
  @type stored_map :: %{optional(tier()) => %{optional(entry_key()) => map()}}

  @doc """
  Seeds `<root>/.spec/realization_hashes.json` with the given realization
  entries.

  `entries` is a `%{tier => %{key => hash_bin}}` map; raw binary hashes are
  hex-encoded and stamped with the current hasher version before being
  written. The baseline file is replaced by the encoded form of `entries`.

  Pass `%{}` to materialize an empty baseline file (useful for
  cold-but-present-file trajectories).

  Returns `:ok`.
  """
  @spec seed(Path.t(), seed_map()) :: :ok
  def seed(root, entries) when is_binary(root) and is_map(entries) do
    encoded =
      Map.new(entries, fn {tier, tier_entries} ->
        unless is_binary(tier) do
          raise ArgumentError,
                "StateJsonFixture.seed/2: tier keys must be strings, got: #{inspect(tier)}"
        end

        unless is_map(tier_entries) do
          raise ArgumentError,
                "StateJsonFixture.seed/2: tier #{inspect(tier)} must map to a map, " <>
                  "got: #{inspect(tier_entries)}"
        end

        encoded_entries =
          Map.new(tier_entries, fn {key, hash} -> {key, encode_entry(key, hash)} end)

        {tier, encoded_entries}
      end)

    HashStore.write(root, encoded)
  end

  @doc """
  Reads the committed baseline for `root`.

  Returns the same shape `HashStore.read/1` returns — a tier → key → entry
  map where each entry is `%{"hash" => hex, "hasher_version" => int}`. When
  the baseline is missing or malformed, returns `%{}`.
  """
  @spec read(Path.t()) :: stored_map()
  def read(root) when is_binary(root) do
    HashStore.read(root)
  end

  @doc """
  Asserts that `root`'s committed baseline contains an entry for `tier`
  and `key`.

  Returns the stored entry map (`%{"hash" => hex, "hasher_version" => int}`)
  on success. Raises `ExUnit.AssertionError` with a helpful message when
  the tier or key is missing — the message includes the tiers and keys
  that *are* present so test failures are quick to diagnose.
  """
  @spec assert_state_contains(Path.t(), tier(), entry_key()) :: map()
  def assert_state_contains(root, tier, key)
      when is_binary(root) and is_binary(tier) and is_binary(key) do
    realization = read(root)

    case Map.fetch(realization, tier) do
      {:ok, tier_entries} ->
        case Map.fetch(tier_entries, key) do
          {:ok, entry} ->
            entry

          :error ->
            raise ExUnit.AssertionError,
              message:
                "expected baseline tier #{inspect(tier)} to contain entry " <>
                  "#{inspect(key)}, but tier has only: " <>
                  inspect(Map.keys(tier_entries))
        end

      :error ->
        raise ExUnit.AssertionError,
          message:
            "expected the baseline to contain tier #{inspect(tier)}, " <>
              "but it has only tiers: " <>
              inspect(Map.keys(realization)) <>
              " (baseline path: " <> Path.join(root, HashStore.baseline_rel()) <> ")"
    end
  end

  # ---- Internal -----------------------------------------------------------

  defp encode_entry(_key, hash) when is_binary(hash) do
    %{
      "hash" => Base.encode16(hash, case: :lower),
      "hasher_version" => HashStore.hasher_version()
    }
  end

  defp encode_entry(key, other) do
    raise ArgumentError,
          "StateJsonFixture.seed/2: hash for #{inspect(key)} must be a raw binary " <>
            "(e.g. :crypto.hash(:sha256, \"x\")), got: #{inspect(other)}"
  end
end
