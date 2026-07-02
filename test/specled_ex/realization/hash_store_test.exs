defmodule SpecLedEx.Realization.HashStoreTest do
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.binding.hash_store_atomic"]

  alias SpecLedEx.Realization.HashStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "specled_hashstore_#{:erlang.unique_integer([:positive])}")

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
              "Foo.bar/1" => %{
                "hash" => "original",
                "hasher_version" => HashStore.hasher_version()
              }
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

  describe "merge/2" do
    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "merges into empty state.json — creates the realization key", %{root: root} do
      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      path = Path.join([root, ".spec", "state.json"])
      decoded = Jason.decode!(File.read!(path))

      assert decoded["realization"]["api_boundary"]["Foo.bar/1"]["hash"] == "a1"

      read = HashStore.read(root)
      assert read["api_boundary"]["Foo.bar/1"]["hash"] == "a1"
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "preserves non-seeded tier entries (different tier untouched)", %{root: root} do
      SpecLedEx.StateJsonFixture.seed(root, %{
        "api_boundary" => %{"Foo.bar/1" => :crypto.hash(:sha256, "kept-api")},
        "implementation" => %{"Foo.bar/1" => :crypto.hash(:sha256, "kept-impl")}
      })

      # Seed only api_boundary with a NEW key — implementation tier must be untouched.
      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "New.entry/0" => %{"hash" => "n1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      read = HashStore.read(root)

      assert read["api_boundary"]["Foo.bar/1"]["hash"] ==
               Base.encode16(:crypto.hash(:sha256, "kept-api"), case: :lower)

      assert read["api_boundary"]["New.entry/0"]["hash"] == "n1"

      assert read["implementation"]["Foo.bar/1"]["hash"] ==
               Base.encode16(:crypto.hash(:sha256, "kept-impl"), case: :lower)
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "preserves non-seeded entries within the same tier", %{root: root} do
      SpecLedEx.StateJsonFixture.seed(root, %{
        "api_boundary" => %{
          "Keep.me/0" => :crypto.hash(:sha256, "kept"),
          "Replace.me/0" => :crypto.hash(:sha256, "old")
        }
      })

      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Add.me/0" => %{"hash" => "added", "hasher_version" => HashStore.hasher_version()}
          }
        })

      read = HashStore.read(root)

      assert Map.keys(read["api_boundary"]) |> Enum.sort() ==
               ["Add.me/0", "Keep.me/0", "Replace.me/0"]

      assert read["api_boundary"]["Keep.me/0"]["hash"] ==
               Base.encode16(:crypto.hash(:sha256, "kept"), case: :lower)
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "replaces a same-key entry within a tier", %{root: root} do
      SpecLedEx.StateJsonFixture.seed(root, %{
        "api_boundary" => %{"Foo.bar/1" => :crypto.hash(:sha256, "old")}
      })

      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "new-hex", "hasher_version" => HashStore.hasher_version()}
          }
        })

      read = HashStore.read(root)
      assert read["api_boundary"]["Foo.bar/1"]["hash"] == "new-hex"
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "stamps hasher_version on seed entries that lack it", %{root: root} do
      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{"Foo.bar/1" => %{"hash" => "abc"}}
        })

      read = HashStore.read(root)
      assert read["api_boundary"]["Foo.bar/1"]["hasher_version"] == HashStore.hasher_version()
      assert read["api_boundary"]["Foo.bar/1"]["hash"] == "abc"
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "preserves unrelated top-level keys in state.json", %{root: root} do
      path = Path.join([root, ".spec", "state.json"])
      File.write!(path, Jason.encode!(%{"other_section" => %{"kept" => true}}))

      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      decoded = Jason.decode!(File.read!(path))

      assert decoded["other_section"] == %{"kept" => true}
      assert decoded["realization"]["api_boundary"]["Foo.bar/1"]["hash"] == "a1"
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "atomic write — state.json.tmp is removed after merge", %{root: root} do
      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      path = Path.join([root, ".spec", "state.json"])
      assert File.regular?(path)
      refute File.exists?(path <> ".tmp")
    end

    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "write/2 retains replacement semantics — non-seeded tier entries are gone after write/2",
         %{root: root} do
      # Confirms write/2 was not changed to merge semantics. This is the
      # complement to merge/2 preserving non-seeded entries.
      SpecLedEx.StateJsonFixture.seed(root, %{
        "api_boundary" => %{"Old.entry/0" => :crypto.hash(:sha256, "old")}
      })

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "New.entry/0" => %{"hash" => "n1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      read = HashStore.read(root)
      refute Map.has_key?(read["api_boundary"], "Old.entry/0")
      assert read["api_boundary"]["New.entry/0"]["hash"] == "n1"
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
