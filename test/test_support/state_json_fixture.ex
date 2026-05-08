defmodule SpecLedEx.StateJsonFixture do
  @moduledoc """
  Test helpers for driving multi-trajectory `.spec/state.json` fixtures.

  The realization tier-implication work needs to test what `mix spec.check`
  does across four state.json trajectories per binding entry:

    * **cold** — state.json missing entirely (a fresh checkout / first run).
    * **warm** — state.json present, every entry is committed and current.
    * **seeded** — state.json present, the entry under test is missing
      (silent-seed pass should compute and write its hash on this run).
    * **dangling** — state.json present, the entry under test points at
      an MFA or module that cannot be resolved at runtime.

  These helpers compose the trajectory in a tmp `root` without touching the
  project's real `.spec/state.json`. Pin a tmp root in test setup, then call
  `seed/2` to lay down a starting state and `read/1` or
  `assert_state_contains/3` to inspect it after the system under test has
  run.

  ## Shape

  The realization map is the tier → key → hash shape stored under
  `state["realization"]`:

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
  state.json matches what `HashStore.write/2` would have produced.

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

  @state_rel Path.join(".spec", "state.json")

  @typedoc "Tier name as it appears in state.json (e.g. \"api_boundary\")."
  @type tier :: String.t()

  @typedoc "MFA string (\"Foo.bar/1\") or bare-module string (\"My.Mod\")."
  @type entry_key :: String.t()

  @typedoc "Tier-keyed map of entry → raw hash binary."
  @type seed_map :: %{optional(tier()) => %{optional(entry_key()) => binary()}}

  @typedoc "Tier-keyed map of entry → stored hash entry (decoded from state.json)."
  @type stored_map :: %{optional(tier()) => %{optional(entry_key()) => map()}}

  @doc """
  Seeds `<root>/.spec/state.json` with the given realization entries.

  `entries` is a `%{tier => %{key => hash_bin}}` map; raw binary hashes are
  hex-encoded and stamped with the current hasher version before being
  written. Existing top-level keys in state.json (sections other than
  `"realization"`) are preserved; the `"realization"` section is replaced
  by the encoded form of `entries`.

  Pass `%{}` to materialize an empty `"realization"` section (useful for
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
  Reads the realization section of `<root>/.spec/state.json`.

  Returns the same shape `HashStore.read/1` returns — a tier → key → entry
  map where each entry is `%{"hash" => hex, "hasher_version" => int}`. When
  state.json is missing or malformed, returns `%{}`.
  """
  @spec read(Path.t()) :: stored_map()
  def read(root) when is_binary(root) do
    HashStore.read(root)
  end

  @doc """
  Asserts that `<root>/.spec/state.json` contains an entry for `tier` and
  `key`.

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
                "expected state.json tier #{inspect(tier)} to contain entry " <>
                  "#{inspect(key)}, but tier has only: " <>
                  inspect(Map.keys(tier_entries))
        end

      :error ->
        raise ExUnit.AssertionError,
          message:
            "expected state.json to contain tier #{inspect(tier)}, " <>
              "but state has only tiers: " <> inspect(Map.keys(realization)) <>
              " (state.json path: " <> Path.join(root, @state_rel) <> ")"
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
