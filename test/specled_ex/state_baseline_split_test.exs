defmodule SpecLedEx.StateBaselineSplitTest do
  @moduledoc """
  Covers the split of the committed realization baseline out of
  `.spec/state.json`: regenerating state.json must never alter
  `.spec/realization_hashes.json`, and the migration task hoists a legacy
  embedded baseline into the dedicated file before state.json is untracked.
  """
  use ExUnit.Case, async: true

  alias SpecLedEx.Realization.HashStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_baseline_split_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp baseline_path(root), do: Path.join([root, ".spec", "realization_hashes.json"])
  defp state_path(root), do: Path.join([root, ".spec", "state.json"])

  defp committed_entry(seed) do
    %{
      "hash" => Base.encode16(:crypto.hash(:sha256, seed), case: :lower),
      "hasher_version" => HashStore.hasher_version()
    }
  end

  describe "state.json is fully derived" do
    @tag spec: ["specled.index.state_fully_derived"]
    test "regenerating state.json does not alter the committed baseline", %{root: root} do
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{"Foo.bar/1" => committed_entry("committed")}
        })

      before = File.read!(baseline_path(root))

      SpecLedEx.write_state(%{}, nil, root)
      SpecLedEx.write_state(%{}, nil, root)

      assert File.read!(baseline_path(root)) == before

      decoded = Jason.decode!(File.read!(state_path(root)))
      refute Map.has_key?(decoded, "realization")
    end

    @tag spec: ["specled.index.state_fully_derived"]
    test "merge-conflict ritual (discard state.json, regenerate) preserves the baseline",
         %{root: root} do
      entry = committed_entry("committed-on-main")

      :ok = HashStore.write(root, %{"api_boundary" => %{"Foo.bar/1" => entry}})

      # Conflict resolution ritual: state.json is taken from either side /
      # discarded, then regenerated from the merged tree.
      File.write!(state_path(root), ~s({"conflicted": true}))
      File.rm!(state_path(root))
      SpecLedEx.write_state(%{}, nil, root)

      # The baseline is preserved, not recomputed from the merged tree.
      assert HashStore.read(root)["api_boundary"]["Foo.bar/1"]["hash"] == entry["hash"]
    end
  end

  describe "legacy baseline hoist" do
    @tag spec: ["specled.index.legacy_baseline_hoist"]
    test "migration hoists an embedded legacy baseline into the dedicated file",
         %{root: root} do
      entry = committed_entry("legacy-committed")

      File.write!(
        state_path(root),
        Jason.encode!(%{
          "summary" => %{"subjects" => 1},
          "realization" => %{"api_boundary" => %{"Foo.bar/1" => entry}}
        })
      )

      refute File.exists?(baseline_path(root))

      Mix.Tasks.Spec.Evidence.Migrate.hoist_legacy_realization(root)

      # Hoisted with the committed hash intact — not recomputed.
      decoded = Jason.decode!(File.read!(baseline_path(root)))
      assert decoded["api_boundary"]["Foo.bar/1"]["hash"] == entry["hash"]

      # Hoisting alone does not rewrite the legacy file. The full migration
      # untracks it after the fresh check seeds orphan evidence.
      legacy = Jason.decode!(File.read!(state_path(root)))
      assert Map.has_key?(legacy, "realization")
    end

    @tag spec: ["specled.index.legacy_baseline_hoist"]
    test "no hoist once the dedicated file exists — stale embedded section is ignored",
         %{root: root} do
      current = committed_entry("current")

      :ok = HashStore.write(root, %{"api_boundary" => %{"Foo.bar/1" => current}})
      before = File.read!(baseline_path(root))

      File.write!(
        state_path(root),
        Jason.encode!(%{
          "realization" => %{"api_boundary" => %{"Foo.bar/1" => committed_entry("stale")}}
        })
      )

      Mix.Tasks.Spec.Evidence.Migrate.hoist_legacy_realization(root)

      assert File.read!(baseline_path(root)) == before
    end
  end
end
