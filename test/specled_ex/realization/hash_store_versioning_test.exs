defmodule SpecLedEx.Realization.HashStoreVersioningTest do
  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.HashStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_hashstore_ver_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "silent rehash on older hasher_version" do
    test "older-version entries are filtered from the read result", %{root: root} do
      older = HashStore.hasher_version() - 1
      path = Path.join([root, ".spec", "state.json"])

      File.write!(
        path,
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Foo.old/0" => %{"hash" => "abc", "hasher_version" => older},
              "Foo.new/0" => %{"hash" => "def", "hasher_version" => HashStore.hasher_version()}
            }
          }
        })
      )

      read = HashStore.read(root)

      # Older entry is silently dropped — callers rehash + persist
      refute Map.has_key?(read["api_boundary"] || %{}, "Foo.old/0")

      # Current-version entry is preserved
      assert read["api_boundary"]["Foo.new/0"]["hash"] == "def"
    end

    test "no user-visible finding is produced (debug log only)", %{root: root} do
      older = HashStore.hasher_version() - 1
      path = Path.join([root, ".spec", "state.json"])

      File.write!(
        path,
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Foo.old/0" => %{"hash" => "abc", "hasher_version" => older}
            }
          }
        })
      )

      # Read should complete without raising or producing findings.
      # HashStore.read returns only the hashmap — no finding list.
      result = HashStore.read(root)
      assert is_map(result)
    end

    test "rehash callback rewrites entries to current version", %{root: root} do
      older = HashStore.hasher_version() - 1
      path = Path.join([root, ".spec", "state.json"])

      File.write!(
        path,
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Foo.old/0" => %{"hash" => "abc", "hasher_version" => older}
            }
          }
        })
      )

      rehash_fun = fn "api_boundary", "Foo.old/0", _old ->
        {:ok, :crypto.hash(:sha256, "new-content")}
      end

      read = HashStore.read(root, rehash: rehash_fun)

      assert read["api_boundary"]["Foo.old/0"]["hasher_version"] ==
               HashStore.hasher_version()

      # Verify the rehash was also persisted
      re_read = HashStore.read(root)
      assert re_read["api_boundary"]["Foo.old/0"]["hasher_version"] == HashStore.hasher_version()
    end
  end
end
