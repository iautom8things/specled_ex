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

  defp baseline_path(root), do: Path.join([root, ".spec", "realization_hashes.json"])
  defp state_path(root), do: Path.join([root, ".spec", "state.json"])

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

    @tag spec: ["specled.binding.hash_store_dedicated_file"]
    test "persists to .spec/realization_hashes.json and loads back from it", %{root: root} do
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      assert File.regular?(baseline_path(root))

      decoded = Jason.decode!(File.read!(baseline_path(root)))
      assert decoded["api_boundary"]["Foo.bar/1"]["hash"] == "a1"

      assert HashStore.read(root)["api_boundary"]["Foo.bar/1"]["hash"] == "a1"
    end

    @tag spec: ["specled.binding.hash_store_dedicated_file"]
    test "does not create or modify .spec/state.json", %{root: root} do
      File.write!(state_path(root), Jason.encode!(%{"summary" => %{"subjects" => 3}}))
      before = File.read!(state_path(root))

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      assert File.read!(state_path(root)) == before
    end

    @tag spec: ["specled.binding.hash_store_dedicated_file"]
    test "output is deterministic with recursively sorted keys", %{root: root} do
      entry = %{"hash" => "aa", "hasher_version" => HashStore.hasher_version()}

      payload = %{
        "use" => %{"Zeta.Mod" => entry, "Alpha.Mod" => entry},
        "api_boundary" => %{"B.f/1" => entry, "A.f/1" => entry}
      }

      :ok = HashStore.write(root, payload)
      first = File.read!(baseline_path(root))

      :ok = HashStore.write(root, payload)
      second = File.read!(baseline_path(root))

      assert first == second

      # Keys appear in sorted order in the serialized bytes.
      tier_positions =
        for tier <- ["api_boundary", "use"] do
          {pos, _len} = :binary.match(first, "\"#{tier}\"")
          pos
        end

      assert tier_positions == Enum.sort(tier_positions)

      {alpha_pos, _} = :binary.match(first, "\"Alpha.Mod\"")
      {zeta_pos, _} = :binary.match(first, "\"Zeta.Mod\"")
      assert alpha_pos < zeta_pos
    end
  end

  describe "legacy state.json fallback" do
    @tag spec: ["specled.binding.hash_store_legacy_fallback"]
    test "read/1 falls back to state.json's realization key when the dedicated file is absent",
         %{root: root} do
      File.write!(
        state_path(root),
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Foo.bar/1" => %{
                "hash" => "legacy",
                "hasher_version" => HashStore.hasher_version()
              }
            }
          }
        })
      )

      refute File.exists?(baseline_path(root))
      assert HashStore.read(root)["api_boundary"]["Foo.bar/1"]["hash"] == "legacy"
    end

    @tag spec: ["specled.binding.hash_store_legacy_fallback"]
    test "the dedicated file is authoritative once present — embedded section is ignored",
         %{root: root} do
      File.write!(
        state_path(root),
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Foo.bar/1" => %{
                "hash" => "stale-legacy",
                "hasher_version" => HashStore.hasher_version()
              }
            }
          }
        })
      )

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "current", "hasher_version" => HashStore.hasher_version()}
          }
        })

      assert HashStore.read(root)["api_boundary"]["Foo.bar/1"]["hash"] == "current"
    end

    @tag spec: ["specled.binding.hash_store_legacy_fallback"]
    test "merge/2 migrates a legacy embedded baseline into the dedicated file", %{root: root} do
      legacy_hash = Base.encode16(:crypto.hash(:sha256, "committed-on-main"), case: :lower)

      File.write!(
        state_path(root),
        Jason.encode!(%{
          "realization" => %{
            "api_boundary" => %{
              "Legacy.entry/0" => %{
                "hash" => legacy_hash,
                "hasher_version" => HashStore.hasher_version()
              }
            }
          }
        })
      )

      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "New.entry/0" => %{"hash" => "n1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      decoded = Jason.decode!(File.read!(baseline_path(root)))

      # Migrated, not recomputed: the legacy value is carried forward verbatim.
      assert decoded["api_boundary"]["Legacy.entry/0"]["hash"] == legacy_hash
      assert decoded["api_boundary"]["New.entry/0"]["hash"] == "n1"
    end
  end

  describe "atomicity" do
    test "rename-target survives a missing .tmp — prior committed state intact", %{root: root} do
      path = baseline_path(root)

      committed =
        Jason.encode!(%{
          "api_boundary" => %{
            "Foo.bar/1" => %{
              "hash" => "original",
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      File.write!(path, committed)

      # Simulate the crash: .tmp file exists with partial contents, rename never happened
      File.write!(path <> ".tmp", "\"not-valid-json-partial")

      read = HashStore.read(root)

      # The previous committed state is returned intact
      assert read["api_boundary"]["Foo.bar/1"]["hash"] == "original"

      # No partial realization_hashes.json observed (only the .tmp may be present)
      {:ok, raw} = File.read(path)
      assert Jason.decode!(raw)["api_boundary"]["Foo.bar/1"]["hash"] == "original"
    end

    test "write uses tmp file + rename — partial is never the on-disk baseline", %{root: root} do
      path = baseline_path(root)

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a", "hasher_version" => HashStore.hasher_version()}
          }
        })

      # realization_hashes.json exists and is valid JSON
      assert File.regular?(path)
      assert {:ok, _decoded} = Jason.decode(File.read!(path))

      # realization_hashes.json.tmp was removed by rename
      refute File.exists?(path <> ".tmp")
    end
  end

  describe "merge/2" do
    @tag spec: ["specled.realized_by.silent_seed_uses_merge"]
    test "merges into an empty root — creates the baseline file", %{root: root} do
      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      decoded = Jason.decode!(File.read!(baseline_path(root)))

      assert decoded["api_boundary"]["Foo.bar/1"]["hash"] == "a1"

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
    test "atomic write — realization_hashes.json.tmp is removed after merge", %{root: root} do
      :ok =
        HashStore.merge(root, %{
          "api_boundary" => %{
            "Foo.bar/1" => %{"hash" => "a1", "hasher_version" => HashStore.hasher_version()}
          }
        })

      path = baseline_path(root)
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
