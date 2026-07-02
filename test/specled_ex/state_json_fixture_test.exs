defmodule SpecLedEx.StateJsonFixtureTest do
  @moduledoc """
  Smoke test for `SpecLedEx.StateJsonFixture` — the test_support helper that
  drives multi-trajectory committed-baseline fixtures for the realized_by
  tier-implication work (specled_-701).

  This file exercises the fixture's three public functions (`seed/2`,
  `read/1`, `assert_state_contains/3`) in a tmp root so that downstream
  stages (S1 HashStore.merge/2, S6 integration scenarios) can rely on
  the fixture without separately re-verifying it.
  """
  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.HashStore
  alias SpecLedEx.StateJsonFixture

  setup do
    root =
      Path.join(System.tmp_dir!(), "specled_state_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "seed/2 + read/1" do
    test "writes the realization map to .spec/realization_hashes.json under the tmp root", %{
      root: root
    } do
      hash_bin = :crypto.hash(:sha256, "head-only")

      :ok =
        StateJsonFixture.seed(root, %{
          "api_boundary" => %{"Foo.bar/1" => hash_bin}
        })

      realization = StateJsonFixture.read(root)

      assert realization["api_boundary"]["Foo.bar/1"]["hash"] ==
               Base.encode16(hash_bin, case: :lower)

      assert realization["api_boundary"]["Foo.bar/1"]["hasher_version"] ==
               HashStore.hasher_version()
    end

    test "supports MFA and bare-module entries side by side", %{root: root} do
      mfa_hash = :crypto.hash(:sha256, "mfa")
      mod_hash = :crypto.hash(:sha256, "module-full-union")

      :ok =
        StateJsonFixture.seed(root, %{
          "api_boundary" => %{"Foo.bar/1" => mfa_hash},
          "implementation" => %{"SpecLedEx.Coverage" => mod_hash}
        })

      realization = StateJsonFixture.read(root)

      assert realization["api_boundary"]["Foo.bar/1"]["hash"] ==
               Base.encode16(mfa_hash, case: :lower)

      assert realization["implementation"]["SpecLedEx.Coverage"]["hash"] ==
               Base.encode16(mod_hash, case: :lower)
    end

    test "produces an on-disk shape that HashStore.read/1 understands", %{root: root} do
      hash_bin = :crypto.hash(:sha256, "round-trip")

      :ok =
        StateJsonFixture.seed(root, %{
          "implementation" => %{"My.Mod.f/0" => hash_bin}
        })

      # The whole point of the fixture is that the system under test
      # (HashStore + downstream readers) sees a baseline shape it
      # already knows how to consume.
      via_hash_store = HashStore.read(root)

      assert via_hash_store["implementation"]["My.Mod.f/0"]["hash"] ==
               Base.encode16(hash_bin, case: :lower)
    end

    test "cold trajectory: read/1 on a missing baseline returns an empty map", %{root: root} do
      # No seed call — no baseline file exists.
      assert StateJsonFixture.read(root) == %{}
    end

    test "seeding twice replaces the realization section", %{root: root} do
      first = :crypto.hash(:sha256, "first")
      second = :crypto.hash(:sha256, "second")

      :ok = StateJsonFixture.seed(root, %{"api_boundary" => %{"Foo.bar/1" => first}})
      :ok = StateJsonFixture.seed(root, %{"api_boundary" => %{"Foo.bar/1" => second}})

      assert StateJsonFixture.read(root)["api_boundary"]["Foo.bar/1"]["hash"] ==
               Base.encode16(second, case: :lower)
    end
  end

  describe "assert_state_contains/3" do
    test "returns the stored entry when present", %{root: root} do
      hash_bin = :crypto.hash(:sha256, "present")

      :ok =
        StateJsonFixture.seed(root, %{
          "api_boundary" => %{"Foo.bar/1" => hash_bin}
        })

      entry = StateJsonFixture.assert_state_contains(root, "api_boundary", "Foo.bar/1")

      assert entry["hash"] == Base.encode16(hash_bin, case: :lower)
      assert entry["hasher_version"] == HashStore.hasher_version()
    end

    test "raises ExUnit.AssertionError when the tier is missing", %{root: root} do
      :ok = StateJsonFixture.seed(root, %{"api_boundary" => %{"Foo.bar/1" => <<0>>}})

      assert_raise ExUnit.AssertionError, ~r/tier "implementation"/, fn ->
        StateJsonFixture.assert_state_contains(root, "implementation", "Anything")
      end
    end

    test "raises ExUnit.AssertionError when the key is missing within an existing tier",
         %{root: root} do
      :ok = StateJsonFixture.seed(root, %{"api_boundary" => %{"Foo.bar/1" => <<0>>}})

      assert_raise ExUnit.AssertionError, ~r/"Other.thing\/0"/, fn ->
        StateJsonFixture.assert_state_contains(root, "api_boundary", "Other.thing/0")
      end
    end
  end

  describe "input validation" do
    test "seed/2 rejects non-binary hash values (e.g. atoms)", %{root: root} do
      assert_raise ArgumentError, ~r/must be a raw binary/, fn ->
        StateJsonFixture.seed(root, %{"api_boundary" => %{"Foo.bar/1" => :not_a_binary}})
      end
    end

    test "seed/2 rejects a non-string tier key", %{root: root} do
      assert_raise ArgumentError, ~r/tier keys must be strings/, fn ->
        StateJsonFixture.seed(root, %{api_boundary: %{"Foo.bar/1" => <<0>>}})
      end
    end

    test "seed/2 rejects a non-map tier value", %{root: root} do
      assert_raise ArgumentError, ~r/must map to a map/, fn ->
        StateJsonFixture.seed(root, %{"api_boundary" => ["not", "a", "map"]})
      end
    end
  end
end
