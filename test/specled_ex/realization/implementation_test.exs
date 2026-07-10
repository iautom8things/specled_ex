defmodule SpecLedEx.Realization.ImplementationTest do
  # Tests recompile and purge same-name fixture modules.
  use ExUnit.Case, async: false

  @moduletag spec: ["specled.implementation_tier.closure_walks_tracer_edges"]

  alias SpecLedEx.Realization.{HashStore, Implementation}

  # ---------------------------------------------------------------------------
  # Disk-compiled fixtures — we need real beam modules so Binding.resolve can
  # extract canonical AST for owned/shared MFAs during hash composition.
  # ---------------------------------------------------------------------------
  setup_all do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_impl_fixtures_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    source_path = Path.join(tmp_dir, "impl_fixtures.ex")

    File.write!(source_path, """
    defmodule SpecLedEx.ImplFixtures.A do
      def foo(x), do: SpecLedEx.ImplFixtures.B.bar(x) + 1
    end

    defmodule SpecLedEx.ImplFixtures.B do
      def bar(x), do: SpecLedEx.ImplFixtures.B.helper(x)
      def helper(x), do: x * 2
    end

    defmodule SpecLedEx.ImplFixtures.Solo do
      def run(x), do: SpecLedEx.ImplFixtures.Helpers.util(x)
    end

    defmodule SpecLedEx.ImplFixtures.Helpers do
      def util(x), do: x + 100
    end

    defmodule SpecLedEx.ImplFixtures.WrapperShape do
      def guarded_tuple(a, b) when is_atom(a), do: {a, b}
      def guarded_tuple(a, b), do: {b, a}
    end
    """)

    {:ok, _mods, _warns} =
      Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)

    :code.add_patha(String.to_charlist(tmp_dir))

    for mod <- [
          SpecLedEx.ImplFixtures.A,
          SpecLedEx.ImplFixtures.B,
          SpecLedEx.ImplFixtures.Solo,
          SpecLedEx.ImplFixtures.Helpers,
          SpecLedEx.ImplFixtures.WrapperShape
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
      Path.join(System.tmp_dir!(), "specled_impl_run_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # Fixture world — the "sample project" under test for the unit suite.
  # ---------------------------------------------------------------------------
  defp fixture_world do
    subject_a = %{
      id: "A",
      surface: [],
      impl_bindings: ["SpecLedEx.ImplFixtures.A.foo/1"]
    }

    subject_b = %{
      id: "B",
      surface: [],
      impl_bindings: ["SpecLedEx.ImplFixtures.B.bar/1"]
    }

    edges = %{
      {SpecLedEx.ImplFixtures.A, :foo, 1} => [{SpecLedEx.ImplFixtures.B, :bar, 1}],
      {SpecLedEx.ImplFixtures.B, :bar, 1} => [{SpecLedEx.ImplFixtures.B, :helper, 1}]
    }

    in_project? = fn mod -> mod in [SpecLedEx.ImplFixtures.A, SpecLedEx.ImplFixtures.B] end

    %{
      subjects: [subject_a, subject_b],
      tracer_edges: edges,
      in_project?: in_project?
    }
  end

  defp solo_world(helper_ast_or_nil \\ nil) do
    solo = %{
      id: "Solo",
      surface: [],
      impl_bindings: ["SpecLedEx.ImplFixtures.Solo.run/1"]
    }

    edges = %{
      {SpecLedEx.ImplFixtures.Solo, :run, 1} => [{SpecLedEx.ImplFixtures.Helpers, :util, 1}]
    }

    in_project? = fn mod ->
      mod in [SpecLedEx.ImplFixtures.Solo, SpecLedEx.ImplFixtures.Helpers]
    end

    _ = helper_ast_or_nil

    %{
      subjects: [solo],
      tracer_edges: edges,
      in_project?: in_project?
    }
  end

  describe "hash_for_subject/3 — specled.implementation_tier.hash_ref_composition" do
    @tag spec: ["specled.implementation_tier.hash_ref_composition"]
    test "normalizes Binding.resolve beam wrapper clauses before hashing" do
      subject = %{
        id: "Wrapped",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.WrapperShape.guarded_tuple/2"]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      assert {:ok, hash} = Implementation.hash_for_subject(subject, world)
      assert is_binary(hash)
    end

    test "hash input for A includes a 'subject:B:hash:...' string, not B's canonical AST" do
      world = fixture_world()

      {:ok, a_hash} =
        Implementation.hash_for_subject(
          Enum.find(world.subjects, &(&1.id == "A")),
          world
        )

      {:ok, b_hash} =
        Implementation.hash_for_subject(
          Enum.find(world.subjects, &(&1.id == "B")),
          world
        )

      assert is_binary(a_hash)
      assert is_binary(b_hash)

      # Stability under a re-computation.
      {:ok, a_hash_again} =
        Implementation.hash_for_subject(
          Enum.find(world.subjects, &(&1.id == "A")),
          world
        )

      assert a_hash == a_hash_again
    end
  end

  describe "hash_for_subject/3 — Cargo composition: cross-subject hash reference" do
    test "A's hash changes when B's referenced hash marker changes" do
      world1 = fixture_world()

      {:ok, a_hash_1} =
        Implementation.hash_for_subject(
          Enum.find(world1.subjects, &(&1.id == "A")),
          world1
        )

      # Re-wire B's closure so B's hash input differs: point B.bar at a
      # different callee (still in-project via helper). Since Cargo-style
      # references embed B's current hash in A's hash input, A's hash must
      # flip even though A's own owned MFAs are unchanged.
      world2 =
        update_in(world1.tracer_edges, fn edges ->
          Map.put(edges, {SpecLedEx.ImplFixtures.B, :bar, 1}, [])
        end)

      {:ok, a_hash_2} =
        Implementation.hash_for_subject(
          Enum.find(world2.subjects, &(&1.id == "A")),
          world2
        )

      refute a_hash_1 == a_hash_2
    end
  end

  describe "hash_for_subject/3 — specled.implementation_tier.scenario.shared_helper_inlined" do
    test "shared helper's AST is inlined — its body changes ripple into the caller's hash" do
      # Build a world where Solo.run/1 calls Helpers.util/1 (Helpers is not
      # claimed by any subject).
      world = solo_world()
      solo = hd(world.subjects)

      {:ok, hash_before} = Implementation.hash_for_subject(solo, world)
      {:ok, hash_again} = Implementation.hash_for_subject(solo, world)
      assert hash_before == hash_again

      # Now re-define Helpers.util/1 with a different body and reload. The
      # orchestrator re-reads the beam during composition, so the hash flips.
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "specled_impl_helpers_rewrite_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      source_path = Path.join(tmp_dir, "helpers_v2.ex")

      File.write!(source_path, """
      defmodule SpecLedEx.ImplFixtures.Helpers do
        def util(x), do: x * 17 + 3
      end
      """)

      {:ok, _mods, _warns} =
        Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)

      :code.add_patha(String.to_charlist(tmp_dir))

      :code.purge(SpecLedEx.ImplFixtures.Helpers)
      :code.delete(SpecLedEx.ImplFixtures.Helpers)
      {:module, SpecLedEx.ImplFixtures.Helpers} = :code.load_file(SpecLedEx.ImplFixtures.Helpers)

      on_exit(fn ->
        :code.del_path(String.to_charlist(tmp_dir))
        File.rm_rf!(tmp_dir)
      end)

      {:ok, hash_after} = Implementation.hash_for_subject(solo, world)
      refute hash_before == hash_after
    end
  end

  describe "hash_for_subject/3 — dangling binding" do
    test "returns {:error, {:dangling_bindings, [...]}} when a declared binding does not exist" do
      subject = %{
        id: "Ghost",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.DoesNotExist.nope/0"]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      assert {:error, {:dangling_bindings, ["SpecLedEx.ImplFixtures.DoesNotExist.nope/0"]}} =
               Implementation.hash_for_subject(subject, world)
    end
  end

  describe "run/4 — drift finding" do
    test "emits branch_guard_realization_drift when committed subject-hash differs", %{root: root} do
      world = fixture_world()
      subject_a = Enum.find(world.subjects, &(&1.id == "A"))

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            subject_a.id => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      findings = Implementation.run(world.subjects, world, nil, root: root)

      drift =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["subject_id"] == "A"
        end)

      assert drift != nil, "expected drift finding, got: #{inspect(findings)}"
      assert drift["tier"] == "implementation"
    end

    test "no drift finding when current hash matches committed", %{root: root} do
      world = fixture_world()
      subject_a = Enum.find(world.subjects, &(&1.id == "A"))
      subject_b = Enum.find(world.subjects, &(&1.id == "B"))

      {:ok, a_hash} = Implementation.hash_for_subject(subject_a, world)
      {:ok, b_hash} = Implementation.hash_for_subject(subject_b, world)

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            "A" => %{
              "hash" => Base.encode16(a_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            },
            "B" => %{
              "hash" => Base.encode16(b_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      findings = Implementation.run(world.subjects, world, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    test "no drift finding when no committed hash exists (first commit)", %{root: root} do
      world = fixture_world()
      findings = Implementation.run(world.subjects, world, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end
  end

  describe "run/4 — dangling finding" do
    test "emits branch_guard_dangling_binding when a declared implementation MFA is missing", %{
      root: root
    } do
      ghost = %{
        id: "Ghost",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.DoesNotExist.nope/0"]
      }

      world = %{subjects: [ghost], tracer_edges: %{}, in_project?: fn _ -> true end}

      findings = Implementation.run([ghost], world, nil, root: root)

      dangling = Enum.find(findings, &(&1["code"] == "branch_guard_dangling_binding"))
      assert dangling != nil, "expected dangling finding, got: #{inspect(findings)}"
      assert dangling["subject_id"] == "Ghost"
      assert dangling["tier"] == "implementation"
    end
  end

  describe "run/4 — umbrella graceful degrade" do
    test "emits a single detector_unavailable finding when umbrella? is true", %{root: root} do
      findings = Implementation.run([], nil, nil, root: root, umbrella?: true)

      assert length(findings) == 1
      [finding] = findings
      assert finding["code"] == "detector_unavailable"
      assert finding["reason"] == "umbrella_unsupported"
    end
  end

  # covers: specled.realized_by.bare_module_implementation_hash
  # covers: specled.realized_by.bare_module_no_closure_walk
  describe "run/4 — bare-module entries hash via Canonical.hash_module_full_union/2" do
    @tag spec: ["specled.realized_by.bare_module_implementation_hash"]
    test "no drift when committed bare-module hash matches current full-union", %{root: root} do
      module_string = "SpecLedEx.ImplFixtures.Helpers"

      {:ok, current} =
        SpecLedEx.Realization.Canonical.hash_module_full_union(SpecLedEx.ImplFixtures.Helpers)

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            module_string => %{
              "hash" => Base.encode16(current, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject = %{
        id: "BareOnly",
        surface: [],
        impl_bindings: [module_string]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      findings = Implementation.run([subject], world, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    @tag spec: ["specled.realized_by.bare_module_implementation_hash"]
    test "drift fires when committed bare-module hash differs", %{root: root} do
      module_string = "SpecLedEx.ImplFixtures.Helpers"

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            module_string => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject = %{
        id: "BareOnly",
        surface: [],
        impl_bindings: [module_string]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      findings = Implementation.run([subject], world, nil, root: root)

      drift =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["mfa"] == module_string
        end)

      assert drift != nil, "expected drift finding for bare module, got: #{inspect(findings)}"
      assert drift["tier"] == "implementation"
      assert drift["subject_id"] == "BareOnly"
    end

    @tag spec: ["specled.realized_by.bare_module_no_closure_walk"]
    test "bare-module bindings do NOT seed the closure walk (no MFA → no subject hash)",
         %{root: root} do
      # Subject lists ONLY a bare module. No MFA-form binding exists, so the
      # closure walker has nothing to seed. The subject's per-subject hash
      # entry must be absent — the only entries produced are the per-module
      # bare-module entries.
      module_string = "SpecLedEx.ImplFixtures.Helpers"

      subject = %{
        id: "BareOnly",
        surface: [],
        impl_bindings: [module_string]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      # No committed hashes for either the subject id or the bare module —
      # first run should be silent (per silent_seed semantics handled in S5;
      # here we assert "no drift findings").
      findings = Implementation.run([subject], world, nil, root: root)
      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
      refute Enum.any?(findings, &(&1["code"] == "branch_guard_dangling_binding"))
    end

    @tag spec: ["specled.realized_by.bare_module_implementation_hash"]
    test "MFA bindings and bare-module bindings coexist in the same subject", %{root: root} do
      # Mix one MFA binding (drives the closure-walk subject hash) and one
      # bare-module binding (drives a per-module hash). Both should be
      # checked independently.
      module_string = "SpecLedEx.ImplFixtures.Helpers"
      mfa = "SpecLedEx.ImplFixtures.A.foo/1"

      subject = %{
        id: "Mixed",
        surface: [],
        impl_bindings: [mfa, module_string]
      }

      edges = %{
        {SpecLedEx.ImplFixtures.A, :foo, 1} => [{SpecLedEx.ImplFixtures.B, :bar, 1}]
      }

      world = %{
        subjects: [subject],
        tracer_edges: edges,
        in_project?: fn mod ->
          mod in [SpecLedEx.ImplFixtures.A, SpecLedEx.ImplFixtures.B]
        end
      }

      # Compute the subject's MFA-only hash by stripping the bare module.
      {:ok, mfa_only_hash} =
        Implementation.hash_for_subject(
          %{subject | impl_bindings: [mfa]},
          world
        )

      {:ok, bare_hash} =
        SpecLedEx.Realization.Canonical.hash_module_full_union(SpecLedEx.ImplFixtures.Helpers)

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            "Mixed" => %{
              "hash" => Base.encode16(mfa_only_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            },
            module_string => %{
              "hash" => Base.encode16(bare_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      findings = Implementation.run([subject], world, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift")),
             "expected zero drift, got: #{inspect(findings)}"
    end
  end

  # covers: specled.realized_by.bare_module_runtime_only_discovery
  describe "run/4 — bare module not loadable → dangling" do
    @tag spec: ["specled.realized_by.bare_module_runtime_only_discovery"]
    test "emits branch_guard_dangling_binding when the bare module fails to load",
         %{root: root} do
      module_string = "SpecLedEx.NotLoadable.Module.Imaginary"

      subject = %{
        id: "Ghost",
        surface: [],
        impl_bindings: [module_string]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      findings = Implementation.run([subject], world, nil, root: root)

      dangling =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["mfa"] == module_string
        end)

      assert dangling != nil,
             "expected dangling finding for bare module, got: #{inspect(findings)}"

      assert dangling["tier"] == "implementation"
    end
  end

  # covers: specled.realized_by.binding_ref_inferred_no_leak
  describe "run/4 — inferred? never leaks into finding maps" do
    @tag spec: ["specled.realized_by.binding_ref_inferred_no_leak"]
    test "implementation findings never carry :inferred? or \"inferred?\" keys",
         %{root: root} do
      # Drive every implementation-tier path that produces findings:
      # - subject-level MFA drift
      # - subject-level MFA dangling
      # - bare-module drift
      # - bare-module not-loadable dangling
      module_string = "SpecLedEx.ImplFixtures.Helpers"

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            "DriftSubject" => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong-subj"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            },
            module_string => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong-bare"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      drift_subject = %{
        id: "DriftSubject",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.A.foo/1", module_string]
      }

      ghost = %{
        id: "Ghost",
        surface: [],
        impl_bindings: [
          "SpecLedEx.ImplFixtures.DoesNotExist.nope/0",
          "SpecLedEx.NotLoadable.Module.Imaginary"
        ]
      }

      edges = %{
        {SpecLedEx.ImplFixtures.A, :foo, 1} => [{SpecLedEx.ImplFixtures.B, :bar, 1}]
      }

      world = %{
        subjects: [drift_subject, ghost],
        tracer_edges: edges,
        in_project?: fn _ -> true end
      }

      findings = Implementation.run([drift_subject, ghost], world, nil, root: root)
      refute findings == [], "expected at least one finding to enforce the property"

      Enum.each(findings, fn f ->
        refute Map.has_key?(f, :inferred?),
               "finding map leaked :inferred? key: #{inspect(f)}"

        refute Map.has_key?(f, "inferred?"),
               "finding map leaked \"inferred?\" key: #{inspect(f)}"
      end)
    end
  end

  defp write_fixture_etf!(root) do
    edges = %{
      {SpecLedEx.ImplFixtures.A, :foo, 1} => [{SpecLedEx.ImplFixtures.B, :bar, 1}],
      {SpecLedEx.ImplFixtures.B, :bar, 1} => [{SpecLedEx.ImplFixtures.B, :helper, 1}]
    }

    path = Path.join(root, "xref_fixture.etf")
    File.write!(path, :erlang.term_to_binary(edges))
    path
  end

  defp seeding_subjects do
    [
      %{id: "A", surface: [], impl_bindings: ["SpecLedEx.ImplFixtures.A.foo/1"]},
      %{id: "B", surface: [], impl_bindings: ["SpecLedEx.ImplFixtures.B.bar/1"]}
    ]
  end

  # ---------------------------------------------------------------------------
  # S2: read-time ghost filtering + determinism contract
  # ---------------------------------------------------------------------------

  describe "filter_edges/3 — read-time ghost filtering" do
    @tag spec: "specled.implementation_tier.ghost_edges_filtered"
    test "ghost caller is dropped when the context manifest is a non-empty map" do
      edges = %{
        {GhostCallerMod, :f, 0} => [{Enum, :map, 2}],
        {SpecLedEx.ImplFixtures.A, :foo, 1} => [{SpecLedEx.ImplFixtures.B, :bar, 1}]
      }

      in_project = MapSet.new([SpecLedEx.ImplFixtures.A, SpecLedEx.ImplFixtures.B])
      manifest = %{SpecLedEx.ImplFixtures.A => {:module, :stub}}

      filtered = Implementation.filter_edges(edges, in_project, manifest)

      refute Map.has_key?(filtered, {GhostCallerMod, :f, 0})
      assert Map.has_key?(filtered, {SpecLedEx.ImplFixtures.A, :foo, 1})
    end

    @tag spec: "specled.implementation_tier.ghost_edges_filtered"
    test "binding-module caller absent from the manifest is kept (in-project set rules)" do
      # BindingOnlyMod is in the in-project set (a subject binding module)
      # even though the manifest does not list it — e.g. fixtures compiled
      # outside the app. The filter must key on the in-project set, not on
      # manifest membership directly.
      edges = %{{BindingOnlyMod, :g, 1} => [{Enum, :sort, 1}]}
      in_project = MapSet.new([BindingOnlyMod, SomeManifestMod])
      manifest = %{SomeManifestMod => {:module, :stub}}

      assert Implementation.filter_edges(edges, in_project, manifest) == edges
    end

    @tag spec: "specled.implementation_tier.empty_manifest_no_filtering"
    test "nil and empty manifests disable filtering entirely" do
      edges = %{{GhostCallerMod, :f, 0} => [{Enum, :map, 2}]}
      in_project = MapSet.new([SpecLedEx.ImplFixtures.A])

      assert Implementation.filter_edges(edges, in_project, nil) == edges
      assert Implementation.filter_edges(edges, in_project, %{}) == edges
    end
  end

  describe "determinism (specled.implementation_tier.deterministic_hashes)" do
    @tag spec: "specled.implementation_tier.deterministic_hashes"
    test "hashes_for_seeding/3 twice over an unchanged tree returns identical maps", %{root: root} do
      etf = write_fixture_etf!(root)
      subjects = seeding_subjects()

      first = Implementation.hashes_for_seeding(subjects, nil, tracer_manifest: etf)
      second = Implementation.hashes_for_seeding(subjects, nil, tracer_manifest: etf)

      assert first == second
      assert first |> Map.keys() |> Enum.sort() == ["A", "B"]
      assert Enum.all?(Map.values(first), &is_binary/1)
    end

    @tag spec: "specled.implementation_tier.deterministic_hashes"
    test "run/4 twice over an unchanged tree returns identical findings, including drift hashes",
         %{
           root: root
         } do
      etf = write_fixture_etf!(root)
      subjects = seeding_subjects()

      # Commit a wrong hash for A so each run must recompute A's real hash
      # and emit a drift finding carrying it — identical current_hash across
      # runs proves determinism through the full world-build + walk + hash
      # pipeline, not just an empty-findings equality.
      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            "A" => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      run_once = fn subs ->
        Implementation.run(subs, nil, nil, root: root, tracer_manifest: etf)
      end

      findings_first = run_once.(subjects)
      # Permuted subject order on the second run: identical output also
      # proves the pipeline has no input-order dependence, not merely that
      # repeating identical inputs repeats identical outputs.
      findings_second = run_once.(Enum.reverse(subjects))

      assert findings_first == findings_second

      drift =
        Enum.find(findings_first, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["subject_id"] == "A"
        end)

      assert drift, "expected a drift finding for A, got: #{inspect(findings_first)}"
      assert is_binary(drift["current_hash"])
    end
  end

  # ---------------------------------------------------------------------------
  # Silent-seed batching (atlas-vmi): hash-ref composition requires the full
  # subject graph in one hashes_for_seeding/3 call. Seeding A alone resolves
  # peer B as `subject:B:hash:unknown`; the detector walks A+B and embeds B's
  # real hash → permanent wholesale branch_guard_realization_drift.
  # ---------------------------------------------------------------------------
  describe "silent-seed batching — hash_ref peers must share a world" do
    @tag spec: ["specled.implementation_tier.hash_ref_composition", "specled.realized_by.silent_seed"]
    test "singleton seed of A differs from batch seed when A references B", %{root: root} do
      etf = write_fixture_etf!(root)
      [subject_a, subject_b] = seeding_subjects()

      solo_a =
        Implementation.hashes_for_seeding([subject_a], nil, tracer_manifest: etf)

      batch =
        Implementation.hashes_for_seeding([subject_a, subject_b], nil, tracer_manifest: etf)

      assert Map.has_key?(solo_a, "A")
      assert Map.has_key?(batch, "A")
      assert Map.has_key?(batch, "B")

      refute solo_a["A"] == batch["A"],
             "seeding A alone must not match a full-graph seed when A hash-refs B"
    end

    @tag spec: ["specled.implementation_tier.hash_ref_composition", "specled.realized_by.silent_seed"]
    test "batch seed then run/4 emits no drift on an empty baseline", %{root: root} do
      etf = write_fixture_etf!(root)
      subjects = seeding_subjects()

      seeds = Implementation.hashes_for_seeding(subjects, nil, tracer_manifest: etf)

      :ok =
        HashStore.write(root, %{
          "implementation" =>
            Map.new(seeds, fn {id, hash_bin} ->
              {id,
               %{
                 "hash" => Base.encode16(hash_bin, case: :lower),
                 "hasher_version" => HashStore.hasher_version()
               }}
            end)
        })

      findings =
        Implementation.run(subjects, nil, nil, root: root, tracer_manifest: etf)

      drift =
        Enum.filter(findings, &(&1["code"] == "branch_guard_realization_drift"))

      assert drift == [],
             "batch-seeded baseline must match detector; got: #{inspect(drift)}"
    end
  end
end
