defmodule SpecLedEx.Realization.HashStoreVersioningTest do
  # async: false — the debug-log assertion below temporarily lowers the global
  # Logger level, which would race with concurrently-running async tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag spec: ["specled.binding.hasher_version_internal"]

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
      path = Path.join([root, ".spec", "realization_hashes.json"])

      File.write!(
        path,
        Jason.encode!(%{
          "api_boundary" => %{
            "Foo.old/0" => %{"hash" => "abc", "hasher_version" => older},
            "Foo.new/0" => %{"hash" => "def", "hasher_version" => HashStore.hasher_version()}
          }
        })
      )

      read = HashStore.read(root)

      # Older entry is silently dropped — callers rehash + persist
      refute Map.has_key?(read["api_boundary"] || %{}, "Foo.old/0")

      # Current-version entry is preserved
      assert read["api_boundary"]["Foo.new/0"]["hash"] == "def"
    end

    test "rehash is debug-log only — nothing at warning level, no finding surfaced",
         %{root: root} do
      older = HashStore.hasher_version() - 1
      path = Path.join([root, ".spec", "realization_hashes.json"])

      File.write!(
        path,
        Jason.encode!(%{
          "api_boundary" => %{
            "Foo.old/0" => %{"hash" => "abc", "hasher_version" => older}
          }
        })
      )

      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      debug_log =
        capture_log(fn ->
          read = HashStore.read(root)

          # No finding structure is surfaced — the return is only the hash
          # map, with the stale entry dropped.
          assert read == %{}
        end)

      assert debug_log =~ "silent rehash triggered for 1 entries"

      # Nothing user-visible: at warning level and above the read is silent.
      warning_log = capture_log([level: :warning], fn -> HashStore.read(root) end)
      assert warning_log == ""
    end

    test "rehash callback rewrites entries to current version", %{root: root} do
      older = HashStore.hasher_version() - 1
      path = Path.join([root, ".spec", "realization_hashes.json"])

      File.write!(
        path,
        Jason.encode!(%{
          "api_boundary" => %{
            "Foo.old/0" => %{"hash" => "abc", "hasher_version" => older}
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
