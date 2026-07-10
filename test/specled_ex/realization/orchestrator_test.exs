defmodule SpecLedEx.Realization.OrchestratorTest do
  # Tests recompile and purge same-name fixture modules.
  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.{ApiBoundary, Binding, Canonical, HashStore, Orchestrator}

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

    {:ok, _mods, _warns} =
      Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)

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

      assert by_tier == [
               "umbrella_unsupported",
               "umbrella_unsupported",
               "umbrella_unsupported",
               "umbrella_unsupported"
             ]
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
  # S5 — expand_implications wired per-layer (subject + per-requirement)
  # ---------------------------------------------------------------------------
  describe "run/2 — expand_implications applied per-layer" do
    @tag spec: "specled.realized_by.implication_invoked_per_layer"
    test "subject impl entry is amplified into api_boundary tier on the same run",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"

      # Seed a wrong api_boundary hash for the MFA so the implication-induced
      # api_boundary entry produces a drift finding (proving the implication
      # was wired into accumulate_tier).
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      # Subject lists the MFA only under implementation; api_boundary is empty.
      subject = subject("impl.amp.subject", %{"implementation" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      drifts =
        Enum.filter(findings, &(&1["code"] == "branch_guard_realization_drift"))

      assert length(drifts) == 1
      [d] = drifts
      assert d["tier"] == "api_boundary"
      assert d["mfa"] == mfa
    end

    @tag spec: "specled.realized_by.implication_invoked_per_layer"
    test "requirement-layer impl entry is amplified into api_boundary tier",
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

      # Subject has no realized_by; requirement carries the implementation entry.
      subject =
        subject(
          "req.amp.subject",
          %{},
          [
            %{
              id: "req.amp.req",
              priority: "must",
              realized_by: %{"implementation" => [mfa]}
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
      assert length(drifts) == 1
      [d] = drifts
      assert d["tier"] == "api_boundary"
      assert d["mfa"] == mfa
      assert d["requirement_id"] == "req.amp.req"
    end

    @tag spec: "specled.realized_by.implication_invoked_per_layer"
    test "implication-inferred dangling entry suppresses api_boundary dangling, keeps impl-tier dangling",
         %{root: root} do
      # Bare MFA that does not resolve. Listed only under implementation.
      mfa = "SpecLedEx.Nonexistent.Inferred.nope/0"

      subject = subject("inf.dangle.subject", %{"implementation" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      api_dangling =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "api_boundary"
        end)

      impl_dangling =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "implementation"
        end)

      # The api_boundary tier suppresses dangling for inferred entries; impl
      # tier (where the author wrote it) emits the surviving dangling.
      assert api_dangling == []
      assert length(impl_dangling) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — post-concat dedup on api_boundary tier (amplification)
  # ---------------------------------------------------------------------------
  describe "run/2 — post-concat dedup on api_boundary tier" do
    @tag spec: "specled.realized_by.implication_amplification_dedup"
    test "subject + requirement both list the same impl MFA → exactly one api_boundary drift",
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

      # Same MFA listed under implementation at BOTH layers. Without the
      # post-concat dedup, the api_boundary tier would receive two binding_refs
      # for the same MFA and emit two drift findings.
      subject =
        subject(
          "amp.subject",
          %{"implementation" => [mfa]},
          [
            %{
              id: "amp.req",
              priority: "must",
              realized_by: %{"implementation" => [mfa]}
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
      assert length(drifts) == 1
      [d] = drifts
      # Subject-layer entries precede requirement-layer entries, so the
      # surviving requirement_id is nil (subject layer's first-seen entry wins).
      assert d["requirement_id"] == nil
      assert d["mfa"] == mfa
    end

    @tag spec: "specled.realized_by.implication_amplification_dedup"
    test "implementation tier does NOT collapse subject + requirement entries (subject impl_bindings still aggregates)",
         %{root: root} do
      # The dedup is api_boundary-only by spec
      # (specled.realized_by.implication_amplification_dedup). The
      # implementation tier accumulates a single subject_map per subject; its
      # impl_bindings list is the *uniq* concat of subject + requirement-layer
      # entries. Listing the same dangling MFA at both layers produces exactly
      # ONE dangling finding from the impl tier (deduplication is by
      # `Enum.uniq` inside accumulate_tier(:implementation, ...)), distinct
      # from the api_boundary post-concat uniq_by — both tiers ultimately emit
      # one finding per unique MFA, but via different mechanisms.
      mfa = "SpecLedEx.Nonexistent.Impl.dup/0"

      subject =
        subject(
          "impl.dup.subject",
          %{"implementation" => [mfa]},
          [
            %{
              id: "impl.dup.req",
              priority: "must",
              realized_by: %{"implementation" => [mfa]}
            }
          ]
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:implementation],
          commit_hashes?: false
        )

      impl_dangling =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "implementation" and
            f["mfa"] == mfa
        end)

      assert length(impl_dangling) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — silent seed pass writes uncommitted hashes via HashStore.merge/2
  # ---------------------------------------------------------------------------
  describe "run/2 — silent seed pass" do
    @tag spec: ["specled.realized_by.silent_seed", "specled.realized_by.silent_seed_uses_merge"]
    test "writes api_boundary baseline for a never-seeded MFA and emits no drift",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      subject = subject("seed.subject", %{"api_boundary" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary]
        )

      assert findings == []

      store = HashStore.read(root)
      assert is_map(get_in(store, ["api_boundary", mfa]))

      {:ok, ast} = Binding.resolve(mfa)
      current = ApiBoundary.hash(ast)
      assert HashStore.fetch(store, "api_boundary", mfa) == current
    end

    @tag spec: ["specled.realized_by.silent_seed", "specled.realized_by.silent_seed_uses_merge"]
    test "seed pass uses merge/2 (preserves a sibling entry in the same tier when drift halts the post-run refresh)",
         %{root: root} do
      # Two entries in api_boundary: one previously committed (drift seeded
      # against), one never committed (will be silently seeded). When drift
      # is detected, the tail-end refresh_and_commit_hashes/3 does NOT run
      # (gated by `not has_drift?(findings)`). That isolates the seed pass:
      # if the seed pass had used write/2 (replacement), the previously
      # committed drift-bearing entry would be clobbered. With merge/2 it
      # survives.
      drift_mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      seed_mfa = "SpecLedEx.OrchestratorFixtures.Mod.baz/1"
      wrong = :crypto.hash(:sha256, "wrong")

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            drift_mfa => %{
              "hash" => Base.encode16(wrong, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject =
        subject(
          "merge.subject",
          %{"api_boundary" => [drift_mfa, seed_mfa]},
          []
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary]
        )

      assert Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))

      store = HashStore.read(root)

      # The previously-committed (wrong) entry survives — proving the seed
      # pass merged on top of existing state rather than replacing it.
      assert HashStore.fetch(store, "api_boundary", drift_mfa) == wrong

      # The never-committed entry was silently seeded.
      {:ok, ast} = Binding.resolve(seed_mfa)
      assert HashStore.fetch(store, "api_boundary", seed_mfa) == ApiBoundary.hash(ast)
    end

    @tag spec: ["specled.realized_by.silent_seed", "specled.realized_by.silent_seed_uses_merge"]
    test "seeds bare-module entries under api_boundary (head-union) and implementation (full-union)",
         %{root: root} do
      bare = "SpecLedEx.OrchestratorFixtures.Mod"

      subject =
        subject(
          "bare.seed.subject",
          %{"implementation" => [bare]},
          []
        )

      _findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation]
        )

      store = HashStore.read(root)

      # Implementation tier seeds the bare module under its module string.
      mod = SpecLedEx.OrchestratorFixtures.Mod
      {:ok, full_hash} = Canonical.hash_module_full_union(mod)
      assert HashStore.fetch(store, "implementation", bare) == full_hash

      # Implication-amplified bare module is seeded under api_boundary too,
      # using the head-union envelope (distinct envelope tag from full-union).
      {:ok, head_hash} = Canonical.hash_module_head_union(mod)
      assert HashStore.fetch(store, "api_boundary", bare) == head_hash
      refute head_hash == full_hash
    end

    @tag spec: ["specled.realized_by.silent_seed", "specled.realized_by.silent_seed_uses_merge"]
    test "seeds implementation closure subject under subject.id when no committed hash",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      subject = subject("closure.seed.subject", %{"implementation" => [mfa]}, [])

      _findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:implementation],
          context: nil
        )

      store = HashStore.read(root)

      # The closure hash is keyed by subject.id under the implementation tier.
      assert is_map(get_in(store, ["implementation", "closure.seed.subject"])),
             "expected closure-hash seed for closure.seed.subject, got #{inspect(store)}"
    end

    @tag spec: ["specled.realized_by.silent_seed", "specled.realized_by.silent_seed_uses_merge"]
    test "clean-run flat-tier refresh preserves implementation baseline (no write wipe)",
         %{root: root} do
      # atlas-vmi: after a clean multi-tier run, refresh_and_commit_hashes used
      # HashStore.write/2 with only flat-tier entries and wiped implementation.
      # Must merge so silent-seeded impl hashes survive into the committed file.
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"

      subject =
        subject(
          "preserve.impl.subject",
          %{"api_boundary" => [mfa], "implementation" => [mfa]},
          []
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          context: nil
        )

      assert findings == []

      store = HashStore.read(root)
      assert is_map(get_in(store, ["api_boundary", mfa]))
      assert is_map(get_in(store, ["implementation", "preserve.impl.subject"])),
             "implementation baseline must survive clean-run refresh, got #{inspect(store)}"
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — silent seed gating
  # ---------------------------------------------------------------------------
  describe "run/2 — seed gating" do
    @tag spec: "specled.realized_by.silent_seed"
    test "commit_hashes?: false disables the seed pass (state.json remains empty)",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      subject = subject("nogate.subject", %{"api_boundary" => [mfa]}, [])

      _ =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      store = HashStore.read(root)
      # No seed should have been written because commit_hashes? is false.
      assert get_in(store, ["api_boundary", mfa]) == nil
    end

    @tag spec: "specled.realized_by.silent_seed"
    test "umbrella?: true skips the seed pass",
         %{root: root} do
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      subject = subject("umbrella.subject", %{"api_boundary" => [mfa]}, [])

      _ =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          umbrella?: true
        )

      store = HashStore.read(root)
      assert get_in(store, ["api_boundary", mfa]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — dangling entries are not seeded
  # ---------------------------------------------------------------------------
  describe "run/2 — dangling entries are not seeded" do
    @tag spec: "specled.realized_by.silent_seed"
    test "dangling MFA does not seed and surfaces a dangling finding",
         %{root: root} do
      mfa = "SpecLedEx.Truly.Nonexistent.dangle/2"
      subject = subject("dangle.seed.subject", %{"api_boundary" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary]
        )

      # Detector emits dangling on the same run.
      assert Enum.any?(findings, fn f ->
               f["code"] == "branch_guard_dangling_binding" and f["mfa"] == mfa
             end)

      # And the seed pass MUST NOT have planted a hash for the dangling MFA.
      store = HashStore.read(root)
      assert get_in(store, ["api_boundary", mfa]) == nil
    end

    @tag spec: "specled.realized_by.silent_seed"
    test "dangling MFA inside an implementation closure does not seed the subject",
         %{root: root} do
      subject =
        subject(
          "dangle.impl.subject",
          %{"implementation" => ["SpecLedEx.Truly.Missing.thing/0"]},
          []
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:implementation]
        )

      assert Enum.any?(findings, &(&1["code"] == "branch_guard_dangling_binding"))

      store = HashStore.read(root)
      assert get_in(store, ["implementation", "dangle.impl.subject"]) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — inferred? does not leak onto findings (regression)
  # ---------------------------------------------------------------------------
  describe "run/2 — inferred? flag does not leak onto findings" do
    @tag spec: "specled.realized_by.binding_ref_inferred_no_leak"
    test "no finding map carries an inferred? key (atom or string)",
         %{root: root} do
      # A run that exercises both authored and inferred entries and produces
      # both drift and dangling findings.
      mfa = "SpecLedEx.OrchestratorFixtures.Mod.foo/1"
      missing = "SpecLedEx.Nonexistent.Inferred.nope/0"

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject =
        subject(
          "inferred.leak.subject",
          %{"implementation" => [mfa, missing]},
          []
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      assert findings != []

      assert Enum.all?(findings, fn f ->
               not Map.has_key?(f, :inferred?) and not Map.has_key?(f, "inferred?")
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # S6 — orchestrator publishes per-(subject, file) attestation map
  # (production-code bindings only; tagged-tests expansion is a later ticket)
  # ---------------------------------------------------------------------------
  describe "run_with_attestations/2 + attestations/2 — production bindings" do
    @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
    test "clean api_boundary binding produces an attestation under its source path",
         %{root: root} do
      # Use a real, stable lib/ module so resolve_with_source returns a known
      # repo-relative source path. `SpecLedEx.Coverage.default_artifact_path/0`
      # lives at `lib/specled_ex/coverage.ex`.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      subject = subject("attest.clean.subject", %{"api_boundary" => [mfa]}, [])

      {findings, attestations} =
        Orchestrator.run_with_attestations(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      assert Enum.empty?(findings),
             "expected clean run, got: #{inspect(findings)}"

      assert get_in(attestations, ["attest.clean.subject", "lib/specled_ex/coverage.ex"]) ==
               {:attested_clean, [mfa]}
    end

    @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
    test "drifted binding does not appear in the attestation map", %{root: root} do
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      # Seed a wrong hash to force a drift finding for this MFA on this run.
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject = subject("attest.drift.subject", %{"api_boundary" => [mfa]}, [])

      {findings, attestations} =
        Orchestrator.run_with_attestations(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      # Drift finding present in findings list.
      assert Enum.any?(findings, fn f ->
               f["code"] == "branch_guard_realization_drift" and f["mfa"] == mfa
             end)

      # And no attestation entry for this (subject, file) pair.
      assert Map.get(attestations, "attest.drift.subject", %{}) == %{}
    end

    @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
    test "dangling binding does not appear in the attestation map", %{root: root} do
      mfa = "SpecLedEx.Truly.Nonexistent.gone/0"

      subject = subject("attest.dangle.subject", %{"api_boundary" => [mfa]}, [])

      {findings, attestations} =
        Orchestrator.run_with_attestations(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      assert Enum.any?(findings, fn f ->
               f["code"] == "branch_guard_dangling_binding" and f["mfa"] == mfa
             end)

      assert Map.get(attestations, "attest.dangle.subject", %{}) == %{}
    end

    @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
    test "multiple clean bindings for the same subject group under their source paths",
         %{root: root} do
      mfa_a = "SpecLedEx.Coverage.default_artifact_path/0"
      mfa_b = "SpecLedEx.Coverage.cover_modules_safe/0"

      subject =
        subject("attest.multi.subject", %{"api_boundary" => [mfa_a, mfa_b]}, [])

      {findings, attestations} =
        Orchestrator.run_with_attestations(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      assert Enum.empty?(findings)

      # Both MFAs live in the same file — single attestation entry with both
      # MFAs in stable subject-then-requirement order.
      assert {:attested_clean, mfas} =
               get_in(attestations, ["attest.multi.subject", "lib/specled_ex/coverage.ex"])

      assert Enum.sort(mfas) == Enum.sort([mfa_a, mfa_b])
    end

    @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
    test "attestations/2 returns just the map; run/2's flat-list shape is unchanged",
         %{root: root} do
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      subject = subject("attest.shape.subject", %{"api_boundary" => [mfa]}, [])
      index = %{"subjects" => [subject]}
      opts = [root: root, enabled_tiers: [:api_boundary], commit_hashes?: false]

      # attestations/2 is the convenience form.
      atts = Orchestrator.attestations(index, opts)
      assert is_map(atts)

      assert get_in(atts, ["attest.shape.subject", "lib/specled_ex/coverage.ex"]) ==
               {:attested_clean, [mfa]}

      # run/2 still returns a flat list of findings (existing callers untouched).
      findings = Orchestrator.run(index, opts)
      assert is_list(findings)
      assert Enum.empty?(findings)

      # run_with_attestations/2 returns both halves.
      {findings2, atts2} = Orchestrator.run_with_attestations(index, opts)
      assert findings2 == findings
      assert atts2 == atts
    end

    @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
    test "production attestation appears even when a tagged_tests verification covers the requirement",
         %{root: root} do
      # Production-code attestation always lands regardless of whether the
      # subject has a `kind: tagged_tests` verification block. Tagged-tests
      # expansion runs on top of production attestation (see the dedicated
      # describe block below), but the production entry must remain.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      subject =
        %{
          "file" => ".spec/specs/attest.taggedtests.subject.spec.md",
          "meta" => %SpecLedEx.Schema.Meta{
            id: "attest.taggedtests.subject",
            status: "active",
            kind: "module",
            realized_by: %{"api_boundary" => [mfa]},
            surface: ["lib/specled_ex/coverage.ex"]
          },
          "requirements" => [
            struct(SpecLedEx.Schema.Requirement, %{
              id: "attest.taggedtests.req",
              priority: "must"
            })
          ],
          "verification" => [
            %{
              "kind" => "tagged_tests",
              "execute" => true,
              "covers" => ["attest.taggedtests.req"]
            }
          ]
        }

      atts =
        Orchestrator.attestations(
          %{
            "subjects" => [subject],
            "test_tags" => %{
              "attest.taggedtests.req" => [%{"file" => "test/coverage_test.exs"}]
            }
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      inner = Map.get(atts, "attest.taggedtests.subject", %{})

      assert Map.has_key?(inner, "lib/specled_ex/coverage.ex"),
             "expected production-code attestation, got: #{inspect(inner)}"
    end
  end

  # ---------------------------------------------------------------------------
  # S7 — tagged-tests attestation expansion
  # ---------------------------------------------------------------------------
  describe "run_with_attestations/2 + attestations/2 — tagged_tests expansion" do
    @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
    test "requirement-level binding that attests clean expands tagged_tests covers into test-file attestations",
         %{root: root} do
      # `scenario.attestation_tagged_tests_expand`: a subject has a requirement
      # `req.a` whose `realized_by.api_boundary` lists a clean MFA, and the
      # subject has a `kind: tagged_tests` verification covering `req.a`. The
      # tag-scan index registers `test/coverage_test.exs` for `req.a`. The
      # attestation map must contain a test-file entry with the same MFA list.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      subject = %{
        "file" => ".spec/specs/tt.expand.subject.spec.md",
        "meta" => %SpecLedEx.Schema.Meta{
          id: "tt.expand.subject",
          status: "active",
          kind: "module",
          realized_by: %{},
          surface: ["lib/specled_ex/coverage.ex"]
        },
        "requirements" => [
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.expand.req.a",
            priority: "must",
            realized_by: %{"api_boundary" => [mfa]}
          })
        ],
        "verification" => [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["tt.expand.req.a"]
          }
        ]
      }

      atts =
        Orchestrator.attestations(
          %{
            "subjects" => [subject],
            "test_tags" => %{
              "tt.expand.req.a" => [%{file: "test/coverage_test.exs"}]
            }
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      inner = Map.get(atts, "tt.expand.subject", %{})

      # Production attestation still present.
      assert Map.get(inner, "lib/specled_ex/coverage.ex") ==
               {:attested_clean, [mfa]}

      # Test file attestation carries the same MFA list as the production
      # attestation.
      assert Map.get(inner, "test/coverage_test.exs") ==
               {:attested_clean, [mfa]}
    end

    @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
    test "tag entries with string-keyed file shape are also recognized",
         %{root: root} do
      # The orchestrator should tolerate `%{file: ...}` and `%{"file" => ...}`
      # equally — both shapes appear in practice (normalize_file_entry preserves
      # whatever shape TagScanner produced; hand-built test indexes may use
      # either form).
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      subject = %{
        "file" => ".spec/specs/tt.expand.string.subject.spec.md",
        "meta" => %SpecLedEx.Schema.Meta{
          id: "tt.expand.string.subject",
          status: "active",
          kind: "module",
          realized_by: %{},
          surface: ["lib/specled_ex/coverage.ex"]
        },
        "requirements" => [
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.expand.string.req",
            priority: "must",
            realized_by: %{"api_boundary" => [mfa]}
          })
        ],
        "verification" => [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["tt.expand.string.req"]
          }
        ]
      }

      atts =
        Orchestrator.attestations(
          %{
            "subjects" => [subject],
            "test_tags" => %{
              "tt.expand.string.req" => [%{"file" => "test/coverage_test.exs"}]
            }
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      inner = Map.get(atts, "tt.expand.string.subject", %{})

      assert Map.get(inner, "test/coverage_test.exs") ==
               {:attested_clean, [mfa]}
    end

    @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
    test "requirement whose binding drifted produces no test-file attestation",
         %{root: root} do
      # `scenario.attestation_tagged_tests_drifted_requirement_no_expand`:
      # same subject and tagged_tests verification as the prior scenario, but
      # the requirement's binding drifted. The drift filters out both the
      # production-code attestation AND the tagged-tests expansion for that
      # requirement.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      # Seed a wrong hash to force a drift finding for this MFA.
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      subject = %{
        "file" => ".spec/specs/tt.drift.subject.spec.md",
        "meta" => %SpecLedEx.Schema.Meta{
          id: "tt.drift.subject",
          status: "active",
          kind: "module",
          realized_by: %{},
          surface: ["lib/specled_ex/coverage.ex"]
        },
        "requirements" => [
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.drift.req",
            priority: "must",
            realized_by: %{"api_boundary" => [mfa]}
          })
        ],
        "verification" => [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["tt.drift.req"]
          }
        ]
      }

      {findings, atts} =
        Orchestrator.run_with_attestations(
          %{
            "subjects" => [subject],
            "test_tags" => %{
              "tt.drift.req" => [%{file: "test/coverage_test.exs"}]
            }
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      # Drift finding for the binding was emitted.
      assert Enum.any?(findings, fn f ->
               f["code"] == "branch_guard_realization_drift" and f["mfa"] == mfa
             end)

      inner = Map.get(atts, "tt.drift.subject", %{})

      refute Map.has_key?(inner, "test/coverage_test.exs"),
             "drifted requirement must not produce a test-file attestation; got: #{inspect(inner)}"

      refute Map.has_key?(inner, "lib/specled_ex/coverage.ex"),
             "drifted binding must not produce a production-code attestation; got: #{inspect(inner)}"
    end

    @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
    test "non-tagged_tests verification kinds do not trigger expansion",
         %{root: root} do
      # The expansion is gated on `kind: tagged_tests`. A `kind: source_file`
      # verification (or any other kind) covering the same requirement must
      # NOT cause test-file entries to be bounced into the attestation map.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      subject = %{
        "file" => ".spec/specs/tt.other.subject.spec.md",
        "meta" => %SpecLedEx.Schema.Meta{
          id: "tt.other.subject",
          status: "active",
          kind: "module",
          realized_by: %{},
          surface: ["lib/specled_ex/coverage.ex"]
        },
        "requirements" => [
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.other.req",
            priority: "must",
            realized_by: %{"api_boundary" => [mfa]}
          })
        ],
        "verification" => [
          %{
            "kind" => "source_file",
            "execute" => true,
            "covers" => ["tt.other.req"],
            "target" => "lib/specled_ex/coverage.ex"
          }
        ]
      }

      atts =
        Orchestrator.attestations(
          %{
            "subjects" => [subject],
            "test_tags" => %{
              "tt.other.req" => [%{file: "test/coverage_test.exs"}]
            }
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      inner = Map.get(atts, "tt.other.subject", %{})

      assert Map.has_key?(inner, "lib/specled_ex/coverage.ex"),
             "production attestation must remain unchanged"

      refute Map.has_key?(inner, "test/coverage_test.exs"),
             "non-tagged_tests verifications must not expand: got #{inspect(inner)}"
    end

    @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
    test "tagged_tests covering a requirement with no realized_by binding does not expand",
         %{root: root} do
      # If a requirement has no realized_by tiers and no production binding
      # attests clean for it, there's nothing to expand. The orchestrator must
      # leave such requirements alone — no test-file entries materialize.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      subject = %{
        "file" => ".spec/specs/tt.norealized.subject.spec.md",
        "meta" => %SpecLedEx.Schema.Meta{
          id: "tt.norealized.subject",
          status: "active",
          kind: "module",
          realized_by: %{},
          surface: ["lib/specled_ex/coverage.ex"]
        },
        "requirements" => [
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.norealized.req.bound",
            priority: "must",
            realized_by: %{"api_boundary" => [mfa]}
          }),
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.norealized.req.bare",
            priority: "must"
          })
        ],
        "verification" => [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["tt.norealized.req.bound", "tt.norealized.req.bare"]
          }
        ]
      }

      atts =
        Orchestrator.attestations(
          %{
            "subjects" => [subject],
            "test_tags" => %{
              "tt.norealized.req.bound" => [%{file: "test/bound_test.exs"}],
              "tt.norealized.req.bare" => [%{file: "test/bare_test.exs"}]
            }
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      inner = Map.get(atts, "tt.norealized.subject", %{})

      # The bound requirement expanded.
      assert Map.get(inner, "test/bound_test.exs") ==
               {:attested_clean, [mfa]}

      # The unbound requirement contributed nothing to expand.
      refute Map.has_key?(inner, "test/bare_test.exs"),
             "requirement without realized_by must not expand: got #{inspect(inner)}"
    end

    @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
    test "tagged_tests covering a requirement whose test_tag entry is missing yields no test attestation",
         %{root: root} do
      # The expansion uses `index["test_tags"][requirement_id]` as the source
      # of test files. If a requirement isn't present in the tag map, there
      # are no test files to attest — and production attestation remains.
      mfa = "SpecLedEx.Coverage.default_artifact_path/0"

      subject = %{
        "file" => ".spec/specs/tt.notag.subject.spec.md",
        "meta" => %SpecLedEx.Schema.Meta{
          id: "tt.notag.subject",
          status: "active",
          kind: "module",
          realized_by: %{},
          surface: ["lib/specled_ex/coverage.ex"]
        },
        "requirements" => [
          struct(SpecLedEx.Schema.Requirement, %{
            id: "tt.notag.req",
            priority: "must",
            realized_by: %{"api_boundary" => [mfa]}
          })
        ],
        "verification" => [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["tt.notag.req"]
          }
        ]
      }

      atts =
        Orchestrator.attestations(
          %{
            "subjects" => [subject],
            # test_tags is present but the requirement is absent from it.
            "test_tags" => %{}
          },
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      inner = Map.get(atts, "tt.notag.subject", %{})

      assert Map.get(inner, "lib/specled_ex/coverage.ex") ==
               {:attested_clean, [mfa]},
             "production attestation must still appear"

      # Only the production entry — no other keys.
      assert Map.keys(inner) == ["lib/specled_ex/coverage.ex"]
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
