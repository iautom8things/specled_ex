defmodule SpecLedEx.Realization.OrchestratorTest do
  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.{ApiBoundary, Binding, HashStore, Orchestrator}

  # ---------------------------------------------------------------------------
  # Compiled fixtures on disk so the tiers can resolve them via beam + AST.
  # Four fixtures exercise: stable MFA (api_boundary + drift), a macro provider
  # (use tier), a module with debug_info stripped (expanded_behavior degrade),
  # and a module to mutate between hash-commit and dispatch.
  # ---------------------------------------------------------------------------
  setup_all do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_orchestrator_fixtures_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    source_path = Path.join(tmp_dir, "orchestrator_fixtures.ex")

    File.write!(source_path, """
    defmodule SpecLedEx.OrchestratorFixtures.Mod do
      def foo(x), do: x + 1
      def baz(y), do: y * 2
    end

    defmodule SpecLedEx.OrchestratorFixtures.NoDebug do
      @compile {:no_debug_info, true}
      def q(v), do: v
    end
    """)

    {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir)
    :code.add_patha(String.to_charlist(tmp_dir))

    for mod <- [
          SpecLedEx.OrchestratorFixtures.Mod,
          SpecLedEx.OrchestratorFixtures.NoDebug
        ] do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end

    on_exit(fn ->
      :code.del_path(String.to_charlist(tmp_dir))
      File.rm_rf!(tmp_dir)
    end)

    {:ok, fixture_dir: tmp_dir}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_orchestrator_run_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "run/2 — binding collection" do
    test "returns [] when no subject declares realized_by", %{root: root} do
      index = %{"subjects" => [subject("no.bindings", %{}, [])]}

      findings = Orchestrator.run(index, root: root, commit_hashes?: false)
      assert findings == []
    end

    test "walks subject-level and requirement-level realized_by separately",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      mfa2 = "SpecLedEx.OrchestratorFixtures.Mod.baz/1"

      # Seed wrong hashes for both so we observe two drift findings distinguished
      # by requirement_id.
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "seed-1"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            },
            mfa2 => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "seed-2"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject =
        subject(
          "mixed.subject",
          %{"api_boundary" => [mfa]},
          [
            %{
              id: "mixed.req",
              priority: "must",
              realized_by: %{"api_boundary" => [mfa2]}
            }
          ]
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      drifts = Enum.filter(findings, &(&1["code"] == "branch_guard_realization_drift"))
      assert length(drifts) == 2

      subj_level = Enum.find(drifts, &(&1["mfa"] == mfa))
      req_level = Enum.find(drifts, &(&1["mfa"] == mfa2))

      assert subj_level["subject_id"] == "mixed.subject"
      assert subj_level["requirement_id"] == nil

      assert req_level["subject_id"] == "mixed.subject"
      assert req_level["requirement_id"] == "mixed.req"
    end

    test "uses list of subjects even when only some declare realized_by",
         %{root: root} do
      subj_with = subject("has.bindings", %{"api_boundary" => ["Missing.Mod.missing/1"]}, [])
      subj_without = subject("empty.subject", %{}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subj_without, subj_with]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      dangling = Enum.filter(findings, &(&1["code"] == "branch_guard_dangling_binding"))
      assert length(dangling) == 1
      assert hd(dangling)["subject_id"] == "has.bindings"
    end
  end

  describe "run/2 — tier dispatch + drift" do
    test "emits exactly one drift finding with tier: api_boundary when api_boundary hash differs",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject = subject("drift.subject", %{"api_boundary" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      drift_findings = Enum.filter(findings, &(&1["code"] == "branch_guard_realization_drift"))
      assert length(drift_findings) == 1

      [drift] = drift_findings
      assert drift["tier"] == "api_boundary"
      assert drift["subject_id"] == "drift.subject"
      assert drift["mfa"] == mfa
    end

    test "emits dangling finding when binding does not resolve", %{root: root} do
      subject =
        subject("dangle.subject", %{"api_boundary" => ["SpecLedEx.Nonexistent.Mod.nope/3"]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      dangling = Enum.filter(findings, &(&1["code"] == "branch_guard_dangling_binding"))
      assert length(dangling) == 1
      [d] = dangling
      assert d["subject_id"] == "dangle.subject"
      assert d["tier"] == "api_boundary"
    end
  end

  describe "run/2 — umbrella graceful degrade" do
    test "threads umbrella? to every enabled tier and each emits a single detector_unavailable",
         %{root: root} do
      subject = subject("any.subject", %{"api_boundary" => ["Any.Mod.foo/1"]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :expanded_behavior, :typespecs, :use],
          umbrella?: true,
          commit_hashes?: false
        )

      by_tier =
        findings
        |> Enum.filter(&(&1["code"] == "detector_unavailable"))
        |> Enum.map(&(&1["reason"] || Map.get(&1, :reason)))

      assert by_tier == ["umbrella_unsupported", "umbrella_unsupported",
                         "umbrella_unsupported", "umbrella_unsupported"]
    end
  end

  describe "run/2 — debug_info_stripped degrade (expanded_behavior)" do
    test "emits detector_unavailable once per module with stripped debug_info",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.NoDebug.q/1"
      subject = subject("nodbg.subject", %{"expanded_behavior" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:expanded_behavior],
          commit_hashes?: false
        )

      detector =
        Enum.filter(findings, fn f ->
          f["code"] == "detector_unavailable" and f["reason"] == "debug_info_stripped"
        end)

      assert length(detector) == 1
      [d] = detector
      assert d["tier"] == "expanded_behavior"
    end
  end

  describe "run/2 — hash commit on clean run" do
    test "writes api_boundary baseline when no drift is detected", %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"

      # No committed hash yet, no drift possible on first run.
      subject = subject("baseline.subject", %{"api_boundary" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary]
        )

      # No drift on first run.
      assert Enum.empty?(findings)

      # The baseline MUST have been committed so a subsequent run finds the
      # committed hash matching current.
      store = HashStore.read(root)
      entry = get_in(store, ["api_boundary", mfa])
      assert is_map(entry), "expected committed baseline hash for #{mfa}, got #{inspect(store)}"

      # The committed hash must equal the current ApiBoundary.hash output.
      {:ok, ast} = Binding.resolve(mfa)
      current = ApiBoundary.hash(ast)
      assert HashStore.fetch(store, "api_boundary", mfa) == current
    end

    test "does NOT commit when drift is detected", %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      wrong = :crypto.hash(:sha256, "wrong")

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(wrong, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject = subject("nocommit.subject", %{"api_boundary" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary]
        )

      assert Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))

      # The wrong hash MUST still be in the store — we did not overwrite.
      store = HashStore.read(root)
      assert HashStore.fetch(store, "api_boundary", mfa) == wrong
    end
  end

  describe "run/2 — implementation tier aggregates per subject" do
    test "collects subject-level + requirement-level impl MFAs into one subject map",
         %{root: root} do
      # Drive the implementation tier with a dangling binding to observe that
      # the aggregation walked both sources. A non-resolving MFA emits one
      # dangling finding from Implementation.run.
      subject =
        subject(
          "impl.subject",
          %{"implementation" => ["Missing.Subj.a/0"]},
          [
            %{
              id: "impl.req",
              priority: "must",
              realized_by: %{"implementation" => ["Missing.Subj.b/0"]}
            }
          ]
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:implementation],
          commit_hashes?: false
        )

      dangling = Enum.filter(findings, &(&1["code"] == "branch_guard_dangling_binding"))

      # Both declared MFAs should be reported as dangling by the impl tier.
      mfas = Enum.map(dangling, & &1["mfa"]) |> Enum.sort()
      assert mfas == ["Missing.Subj.a/0", "Missing.Subj.b/0"]
    end
  end

  describe "default_tiers/0" do
    test "returns the four flat-binding tiers in a stable order (impl is opt-in)" do
      assert Orchestrator.default_tiers() ==
               [:api_boundary, :expanded_behavior, :typespecs, :use]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp subject(id, realized_by, requirements) do
    %{
      "file" => ".spec/specs/#{id}.spec.md",
      "meta" => %SpecLedEx.Schema.Meta{
        id: id,
        status: "active",
        kind: "module",
        realized_by: realized_by,
        surface: ["lib/#{id}.ex"]
      },
      "requirements" =>
        Enum.map(requirements, fn r ->
          struct(SpecLedEx.Schema.Requirement, Map.take(r, [:id, :priority, :realized_by]))
        end)
    }
  end
end
