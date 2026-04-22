defmodule SpecLedEx.Realization.HashStoreTest do
  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.HashStore

  setup do
    root = Path.join(System.tmp_dir!(), "specled_hashstore_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "write/2 + read/1" do
    test "round-trips a simple realization payload", %{root: root} do
      payload = %{
        "api_boundary" => %{
          "Foo.bar/1" => %{
            "hash" => "deadbeef",
            "hasher_version" => HashStore.hasher_version()
          }
        }
      }

      :ok = HashStore.write(root, payload)

      assert HashStore.read(root) == payload
    end

    test "stamps hasher_version onto entries missing it", %{root: root} do
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{"Foo.bar/1" => %{"hash" => "abc"}}
        })

      read = HashStore.read(root)
      assert read["api_boundary"]["Foo.bar/1"]["hasher_version"] == HashStore.hasher_version()
    end

    test "preserves unrelated keys already in state.json", %{root: root} do
      path = Path.join([root, ".spec", "state.json"])
      File.write!(path, Jason.encode!(%{"other_section" => %{"kept" => true}}))

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      {:ok, raw} = File.read(path)
      decoded = Jason.decode!(raw)

      assert decoded["other_section"] == %{"kept" => true}
      assert decoded["realization"]["api_boundary"]["Foo.bar/1"]["hash"] == "a1"
    end
  end

  describe "atomicity" do
    test "rename-target survives a missing .tmp — prior committed state intact", %{root: root} do
      path = Path.join([root, ".spec", "state.json"])

      committed =
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Foo.bar/1" => %{"hash" => "original", "hasher_version" => HashStore.hasher_version()}
            }
          }
        })

      File.write!(path, committed)

      # Simulate the crash: .tmp file exists with partial contents, rename never happened
      File.write!(path <> ".tmp", "\"not-valid-json-partial")

      read = HashStore.read(root)

      # The previous committed state is returned intact
      assert read["api_boundary"]["Foo.bar/1"]["hash"] == "original"

      # No partial state.json observed (only state.json.tmp may be present)
      {:ok, raw} = File.read(path)
      assert Jason.decode!(raw)["realization"]["api_boundary"]["Foo.bar/1"]["hash"] == "original"
    end

    test "write uses tmp file + rename — partial is never the on-disk state.json", %{root: root} do
      path = Path.join([root, ".spec", "state.json"])

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a", "hasher_version" => HashStore.hasher_version()}
          }
        })

      # state.json exists and is valid JSON
      assert File.regular?(path)
      assert {:ok, _decoded} = Jason.decode(File.read!(path))

      # state.json.tmp was removed by rename
      refute File.exists?(path <> ".tmp")
    end
  end

  describe "fetch/3" do
    test "returns nil for unknown tier or mfa", %{root: root} do
      :ok = HashStore.write(root, %{})
      realization = HashStore.read(root)

      assert HashStore.fetch(realization, "api_boundary", "Foo.bar/1") == nil
    end

    test "returns decoded binary for known entries", %{root: root} do
      hash_hex = Base.encode16(:crypto.hash(:sha256, "x"), case: :lower)

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => hash_hex, "hasher_version" => HashStore.hasher_version()}
          }
        })

      realization = HashStore.read(root)
      bytes = HashStore.fetch(realization, "api_boundary", "Foo.bar/1")
      assert bytes == :crypto.hash(:sha256, "x")
    end
  end

  describe "entry/1" do
    test "builds a store-ready entry from a normalized AST" do
      ast = Code.string_to_quoted!("def f(a), do: a")
      normalized = SpecLedEx.Realization.Canonical.normalize(ast)
      entry = HashStore.entry(normalized)

      assert is_binary(entry["hash"])
      assert entry["hasher_version"] == HashStore.hasher_version()
      assert String.length(entry["hash"]) == 64
    end
  end
end
