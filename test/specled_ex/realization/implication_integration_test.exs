defmodule SpecLedEx.Realization.ImplicationIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the realized_by tier-implication feature.

  These exercise the full `Orchestrator.run/2` path against compiled-on-disk
  fixture modules and a per-test tmp `<root>/.spec/state.json` driven via
  `SpecLedEx.StateJsonFixture`. Each `describe` block maps one-to-one to a
  scenario in `.spec/specs/realized_by.spec.md`:

    * `implication_drift_both_tiers` — head change fires drift on both
      api_boundary AND implementation tiers; body-only change fires only
      implementation drift.
    * `existing_duplication_validator_warns` — same MFA in both
      api_boundary and implementation produces a `realized_by_redundant_dup`
      warning from `mix spec.validate`'s shared check helper.
    * `bare_module_first_run_silent_seed` + `bare_module_drift_after_seed` —
      first run silently seeds head-union (api_boundary) and full-union
      (implementation) hashes; a subsequent change to the module fires drift.
    * `bare_module_export_added` — adding a public function changes both the
      head-union and full-union hashes.
    * `dangling_implication_once` — a dangling MFA listed only under
      `implementation` produces exactly one `branch_guard_dangling_binding`
      tagged `tier=implementation`; the inferred api_boundary entry stays
      silent.
    * `bare_module_not_loadable_dangles` — a bare module that fails
      `Code.ensure_loaded/1` produces a dangling finding tagged
      `tier=implementation` and is not silently seeded.
    * `inferred_flag_does_not_leak` — across the above scenarios, no
      finding map carries an `inferred?` key (atom or string).

  Fixture modules are compiled into a per-`setup_all` tmp dir and added to
  the code path. To exercise drift after seeding, individual tests rewrite
  the fixture source, recompile via `Kernel.ParallelCompiler`, purge + reload
  the BEAM, then re-run the orchestrator. The recompile step is restricted
  to fresh module names per test so cross-test interference is impossible.
  """

  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.{Canonical, HashStore, Orchestrator}
  alias SpecLedEx.StateJsonFixture
  alias SpecLedEx.Validator.RealizedByDedupCheck

  # ---------------------------------------------------------------------------
  # Per-suite fixtures: a small set of stable modules used by scenarios that
  # don't mutate code, plus a tmp dir that scenario-specific tests can
  # rewrite/reload modules into.
  # ---------------------------------------------------------------------------
  setup_all do
    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_implication_integration_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_dir)

    # Stable fixtures used by scenarios that read but never mutate code.
    stable_path = Path.join(fixture_dir, "stable_fixtures.ex")

    File.write!(stable_path, """
    defmodule SpecLedEx.ImplicationFixtures.Stable do
      def foo(x), do: x + 1
      def baz(y), do: y * 2
    end

    defmodule SpecLedEx.ImplicationFixtures.BareTarget do
      def alpha, do: :a
      def beta(x), do: x + 1
    end
    """)

    {:ok, _mods, _warns} =
      Kernel.ParallelCompiler.compile_to_path([stable_path], fixture_dir, return_diagnostics: true)

    :code.add_patha(String.to_charlist(fixture_dir))

    for mod <- [
          SpecLedEx.ImplicationFixtures.Stable,
          SpecLedEx.ImplicationFixtures.BareTarget
        ] do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end

    on_exit(fn ->
      :code.del_path(String.to_charlist(fixture_dir))
      File.rm_rf!(fixture_dir)
    end)

    {:ok, fixture_dir: fixture_dir}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_impl_int_run_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # Scenario 1 — Hard-coupled MFA drift fires on both tiers
  # specled.realized_by.scenario.implication_drift_both_tiers
  # ---------------------------------------------------------------------------
  describe "scenario.implication_drift_both_tiers" do
    @tag spec: [
           "specled.realized_by.scenario.implication_drift_both_tiers",
           "specled.realized_by.implication_drift_both_tiers",
           "specled.realized_by.implication_one_way"
         ]
    test "hard-coupled MFA listed only under implementation: head change drifts both tiers, body-only change drifts implementation only",
         %{fixture_dir: fixture_dir, root: root} do
      mod_name = "SpecLedEx.ImplicationFixtures.HardCoupled1"
      mfa = "#{mod_name}.bar/1"
      mod = String.to_atom("Elixir.#{mod_name}")
      subject_id = mod_name <> ".subject"

      # Compile the head-and-body baseline.
      compile_module!(fixture_dir, "hard_coupled1.ex", """
      defmodule #{mod_name} do
        def bar(x), do: x + 1
      end
      """, [mod])

      # Compute current api_boundary hash (head-only) and implementation
      # closure hash (full AST) directly. We seed both tiers via
      # StateJsonFixture so the test does not depend on the orchestrator's
      # seed pass for this fixture (the silent-seed pass for impl-tier MFAs
      # is exercised under "scenario.bare_module_first_run_silent_seed";
      # the orchestrator's post-run refresh runs HashStore.write/2 for the
      # flat tiers and would clobber the impl seed if we relied on the seed
      # path here).
      {:ok, ast} = SpecLedEx.Realization.Binding.resolve(mfa)
      head_hash = SpecLedEx.Realization.ApiBoundary.hash(ast)

      seed_subject = %{id: subject_id, surface: [], impl_bindings: [mfa]}

      %{^subject_id => impl_hash} =
        SpecLedEx.Realization.Implementation.hashes_for_seeding(
          [seed_subject],
          nil,
          root: root
        )

      :ok =
        StateJsonFixture.seed(root, %{
          "api_boundary" => %{mfa => head_hash},
          "implementation" => %{subject_id => impl_hash}
        })

      # Sanity: both tier entries committed.
      seeded = HashStore.read(root)
      assert HashStore.fetch(seeded, "api_boundary", mfa) == head_hash
      assert HashStore.fetch(seeded, "implementation", subject_id) == impl_hash

      subject = subject(subject_id, %{"implementation" => [mfa]}, [])

      # ---- HEAD CHANGE: argument pattern alteration ----
      compile_module!(fixture_dir, "hard_coupled1.ex", """
      defmodule #{mod_name} do
        def bar({x}), do: x + 1
      end
      """, [mod])

      findings_head =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      drifts =
        Enum.filter(
          findings_head,
          &(&1["code"] == "branch_guard_realization_drift")
        )

      api_drift =
        Enum.filter(drifts, &(&1["tier"] == "api_boundary" and &1["mfa"] == mfa))

      impl_drift =
        Enum.filter(drifts, &(&1["tier"] == "implementation"))

      assert length(api_drift) == 1, "expected one api_boundary drift, got: #{inspect(drifts)}"
      assert length(impl_drift) == 1, "expected one implementation drift, got: #{inspect(drifts)}"

      # No `inferred?` key leaks onto findings (cross-cutting check, see
      # specled.realized_by.binding_ref_inferred_no_leak).
      refute_inferred_leak(findings_head)

      # ---- BODY-ONLY CHANGE: same head, different body ----
      # Re-seed the baseline against the head-only ground state, then mutate
      # only the body so we can observe drift on the body change in
      # isolation.
      compile_module!(fixture_dir, "hard_coupled1.ex", """
      defmodule #{mod_name} do
        def bar(x), do: x + 1
      end
      """, [mod])

      {:ok, ast2} = SpecLedEx.Realization.Binding.resolve(mfa)
      head_hash2 = SpecLedEx.Realization.ApiBoundary.hash(ast2)

      %{^subject_id => impl_hash2} =
        SpecLedEx.Realization.Implementation.hashes_for_seeding(
          [seed_subject],
          nil,
          root: root
        )

      :ok =
        StateJsonFixture.seed(root, %{
          "api_boundary" => %{mfa => head_hash2},
          "implementation" => %{subject_id => impl_hash2}
        })

      compile_module!(fixture_dir, "hard_coupled1.ex", """
      defmodule #{mod_name} do
        def bar(x), do: x * 99
      end
      """, [mod])

      findings_body =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      drifts_body =
        Enum.filter(findings_body, &(&1["code"] == "branch_guard_realization_drift"))

      assert Enum.any?(drifts_body, &(&1["tier"] == "implementation")),
             "expected implementation drift on body-only change, got: #{inspect(drifts_body)}"

      refute Enum.any?(drifts_body, &(&1["tier"] == "api_boundary")),
             "body-only change must NOT trigger api_boundary drift, got: #{inspect(drifts_body)}"

      refute_inferred_leak(findings_body)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — Existing duplication validator-warns
  # specled.realized_by.scenario.existing_duplication_validator_warns
  # ---------------------------------------------------------------------------
  describe "scenario.existing_duplication_validator_warns" do
    @tag spec: [
           "specled.realized_by.scenario.existing_duplication_validator_warns",
           "specled.realized_by.redundant_dup_warning",
           "specled.realized_by.dedup_check_shared_seam"
         ]
    test "MFA in both api_boundary and implementation: validator emits one redundant_dup warning, drift behavior unchanged",
         %{root: root} do
      mfa = "SpecLedEx.ImplicationFixtures.Stable.foo/1"

      # Subject lists the same MFA in both tiers.
      subject =
        subject(
          "dup.subject",
          %{
            "api_boundary" => [mfa],
            "implementation" => [mfa]
          },
          []
        )

      index = %{"subjects" => [subject]}

      # ---- Validator: exactly one redundant_dup warning, MFA-form text ----
      validator_findings = RealizedByDedupCheck.findings(index)

      dup_findings =
        Enum.filter(validator_findings, &(&1["code"] == "realized_by_redundant_dup"))

      assert length(dup_findings) == 1
      [d] = dup_findings
      assert d["subject_id"] == "dup.subject"
      assert d["severity"] == "warning"
      assert d["message"] =~ mfa
      assert d["message"] =~ "mix spec.dedup_realized_by"
      # MFA-form message text per spec:
      assert d["message"] =~ "strict subset of implementation"

      # ---- Drift behavior: implication still tracks the entry under
      # api_boundary even though it's also explicitly listed there. With both
      # the explicit api_boundary entry and the implication-amplified entry,
      # post-concat dedup keeps exactly one api_boundary binding. So a wrong
      # committed api_boundary hash produces exactly ONE drift finding.
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      drift_findings =
        Orchestrator.run(index,
          root: root,
          enabled_tiers: [:api_boundary],
          commit_hashes?: false
        )

      api_drifts =
        Enum.filter(
          drift_findings,
          &(&1["code"] == "branch_guard_realization_drift" and &1["tier"] == "api_boundary" and
              &1["mfa"] == mfa)
        )

      # Exactly one api_boundary drift — proves the explicit listing didn't
      # double-fire alongside the implication-derived entry.
      assert length(api_drifts) == 1

      refute_inferred_leak(drift_findings)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — Bare-module first-run silent seed, then drift on change
  # specled.realized_by.scenario.bare_module_first_run_silent_seed +
  # specled.realized_by.scenario.bare_module_drift_after_seed
  # ---------------------------------------------------------------------------
  describe "scenario.bare_module_first_run_silent_seed + bare_module_drift_after_seed" do
    @tag spec: [
           "specled.realized_by.scenario.bare_module_first_run_silent_seed",
           "specled.realized_by.scenario.bare_module_drift_after_seed",
           "specled.realized_by.bare_module_implementation_hash",
           "specled.realized_by.bare_module_api_boundary_hash",
           "specled.realized_by.silent_seed",
           "specled.realized_by.silent_seed_uses_merge"
         ]
    test "first run silently seeds head- and full-union hashes; subsequent change fires drift",
         %{fixture_dir: fixture_dir, root: root} do
      mod_name = "SpecLedEx.ImplicationFixtures.BareSeed3"
      bare = mod_name
      mod = String.to_atom("Elixir.#{mod_name}")

      compile_module!(fixture_dir, "bare_seed3.ex", """
      defmodule #{mod_name} do
        def alpha, do: :a
      end
      """, [mod])

      # Cold trajectory: state.json missing entirely.
      assert HashStore.read(root) == %{}

      subject = subject("bare.seed.subject", %{"implementation" => [bare]}, [])

      findings_first =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation]
        )

      # No drift findings on the seeding run (silent seed contract).
      drift_or_dangling =
        Enum.filter(findings_first, fn f ->
          f["code"] in ["branch_guard_realization_drift", "branch_guard_dangling_binding"] and
            f["mfa"] == bare
        end)

      assert drift_or_dangling == [],
             "expected no drift/dangling on seeding run, got: #{inspect(drift_or_dangling)}"

      # Both tier entries written via silent seed:
      #   * implementation tier: full-union hash for the bare module
      #   * api_boundary tier:  head-union hash (via implication)
      seeded = StateJsonFixture.read(root)
      assert is_map(get_in(seeded, ["implementation", bare])),
             "expected implementation seed for #{bare}, got: #{inspect(seeded)}"

      assert is_map(get_in(seeded, ["api_boundary", bare])),
             "expected api_boundary seed for #{bare}, got: #{inspect(seeded)}"

      {:ok, head_hash} = Canonical.hash_module_head_union(mod)
      {:ok, full_hash} = Canonical.hash_module_full_union(mod)
      assert HashStore.fetch(seeded, "api_boundary", bare) == head_hash
      assert HashStore.fetch(seeded, "implementation", bare) == full_hash

      # Distinct envelope tags: head-union vs full-union must produce
      # different bytes even on a degenerate module.
      refute head_hash == full_hash

      refute_inferred_leak(findings_first)

      # ---- Drift on subsequent change ----
      # Adding a body to the public function changes the full AST (impl
      # tier's full-union hash) AND the head AST (because the head AST
      # extracted from BEAM debug_info captures the per-clause shape). To
      # demonstrate body-only behavior we'd need to use the same head shape
      # but a different body; the spec scenario only requires "a public
      # function ... is changed (head or body)". Add an inner branch that
      # mutates the body without changing the head's pattern.
      compile_module!(fixture_dir, "bare_seed3.ex", """
      defmodule #{mod_name} do
        def alpha, do: :alpha_changed
      end
      """, [mod])

      findings_drift =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      impl_drift =
        Enum.filter(findings_drift, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["tier"] == "implementation" and
            f["mfa"] == bare
        end)

      assert length(impl_drift) == 1,
             "expected exactly one implementation drift on bare-module body change, got: " <>
               inspect(findings_drift)

      # Body-only change does not touch the head-union hash. Spec wording:
      # "if the change touched a function head, an additional tier=api_boundary
      # drift finding fires; otherwise only the implementation drift fires".
      api_drift =
        Enum.filter(findings_drift, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["tier"] == "api_boundary" and
            f["mfa"] == bare
        end)

      assert api_drift == [],
             "body-only change must not produce api_boundary bare-module drift, got: " <>
               inspect(api_drift)

      refute_inferred_leak(findings_drift)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — Adding public export to bare-module-tracked module fires drift on both tiers
  # specled.realized_by.scenario.bare_module_export_added
  # ---------------------------------------------------------------------------
  describe "scenario.bare_module_export_added" do
    @tag spec: [
           "specled.realized_by.scenario.bare_module_export_added",
           "specled.realized_by.bare_module_api_boundary_hash",
           "specled.realized_by.bare_module_implementation_hash"
         ]
    test "adding a public function to a bare-module-tracked module fires drift on both tiers",
         %{fixture_dir: fixture_dir, root: root} do
      mod_name = "SpecLedEx.ImplicationFixtures.BareExport4"
      bare = mod_name
      mod = String.to_atom("Elixir.#{mod_name}")

      # Baseline: one public function.
      compile_module!(fixture_dir, "bare_export4.ex", """
      defmodule #{mod_name} do
        def alpha, do: :a
      end
      """, [mod])

      subject = subject("bare.export.subject", %{"implementation" => [bare]}, [])

      # Seed via the silent-seed pass.
      _ =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation]
        )

      seeded = HashStore.read(root)
      assert is_binary(HashStore.fetch(seeded, "api_boundary", bare))
      assert is_binary(HashStore.fetch(seeded, "implementation", bare))

      # ---- Add a new public export ----
      compile_module!(fixture_dir, "bare_export4.ex", """
      defmodule #{mod_name} do
        def alpha, do: :a
        def new_thing, do: :new
      end
      """, [mod])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      api_drift =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["tier"] == "api_boundary" and
            f["mfa"] == bare
        end)

      impl_drift =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["tier"] == "implementation" and
            f["mfa"] == bare
        end)

      assert length(api_drift) == 1, "expected one api_boundary drift, got: #{inspect(findings)}"

      assert length(impl_drift) == 1,
             "expected one implementation drift, got: #{inspect(findings)}"

      refute_inferred_leak(findings)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — Dangling MFA reports once tier=implementation
  # specled.realized_by.scenario.dangling_implication_once
  # ---------------------------------------------------------------------------
  describe "scenario.dangling_implication_once" do
    @tag spec: [
           "specled.realized_by.scenario.dangling_implication_once",
           "specled.realized_by.implication_dangling_once",
           "specled.realized_by.binding_ref_inferred_no_leak"
         ]
    test "dangling MFA listed only under implementation: exactly one dangling, tier=implementation, no api_boundary dangling for inferred entry",
         %{root: root} do
      mfa = "SpecLedEx.NoSuchModule.Truly.missing/1"
      subject = subject("dangle.subject", %{"implementation" => [mfa]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      dangling_for_mfa =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["mfa"] == mfa
        end)

      assert length(dangling_for_mfa) == 1,
             "expected exactly one dangling finding for #{mfa}, got: #{inspect(findings)}"

      [d] = dangling_for_mfa
      assert d["tier"] == "implementation"
      assert d["subject_id"] == "dangle.subject"

      api_dangling =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "api_boundary" and
            f["mfa"] == mfa
        end)

      assert api_dangling == [],
             "implication-inferred api_boundary dangling must be suppressed, got: " <>
               inspect(api_dangling)

      # The dangling MFA must NOT have been seeded into state.json
      # (specled.realized_by.silent_seed: dangling entries are not seeded).
      store = HashStore.read(root)
      assert get_in(store, ["api_boundary", mfa]) == nil
      assert get_in(store, ["implementation", mfa]) == nil

      refute_inferred_leak(findings)
    end
  end

  # ---------------------------------------------------------------------------
  # Plus 1 — Bare-module not loadable dangles
  # specled.realized_by.scenario.bare_module_not_loadable_dangles
  # ---------------------------------------------------------------------------
  describe "scenario.bare_module_not_loadable_dangles" do
    @tag spec: [
           "specled.realized_by.scenario.bare_module_not_loadable_dangles",
           "specled.realized_by.bare_module_runtime_only_discovery"
         ]
    test "bare module that fails Code.ensure_loaded fires dangling tier=implementation, no silent seed of stale source-AST hash",
         %{root: root} do
      bare = "SpecLedEx.NotLoadable.BareModule.Imaginary"
      subject = subject("notloadable.subject", %{"implementation" => [bare]}, [])

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      impl_dangling =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "implementation" and
            f["mfa"] == bare
        end)

      assert length(impl_dangling) == 1,
             "expected one implementation dangling finding for bare module, got: " <>
               inspect(findings)

      # Per specled.realized_by.bare_module_runtime_only_discovery: source-AST
      # fallback is not used; the fixture proves no silent seed planted a
      # stale hash for the unloadable module.
      store = HashStore.read(root)
      assert get_in(store, ["api_boundary", bare]) == nil
      assert get_in(store, ["implementation", bare]) == nil

      # The api_boundary dangling for the implication-inferred bare-module
      # entry must be suppressed (binding_ref_inferred_no_leak / dangling
      # implication once).
      api_dangling =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "api_boundary" and
            f["mfa"] == bare
        end)

      assert api_dangling == []

      refute_inferred_leak(findings)
    end
  end

  # ---------------------------------------------------------------------------
  # Plus 2 — Inferred flag does not leak (dedicated regression)
  # specled.realized_by.scenario.inferred_flag_does_not_leak
  # ---------------------------------------------------------------------------
  describe "scenario.inferred_flag_does_not_leak" do
    @tag spec: [
           "specled.realized_by.scenario.inferred_flag_does_not_leak",
           "specled.realized_by.binding_ref_inferred_no_leak"
         ]
    test "no finding map produced by Orchestrator.run/2 carries an inferred? key (atom or string) across drift, dangling, and bare-module paths",
         %{fixture_dir: fixture_dir, root: root} do
      mod_name = "SpecLedEx.ImplicationFixtures.NoLeak7"
      mfa = "#{mod_name}.bar/1"
      mod = String.to_atom("Elixir.#{mod_name}")
      missing_mfa = "SpecLedEx.NoLeak.Missing.gone/0"
      missing_bare = "SpecLedEx.NoLeak.MissingBare.Imaginary"
      bare = "SpecLedEx.ImplicationFixtures.BareTarget"

      compile_module!(fixture_dir, "no_leak7.ex", """
      defmodule #{mod_name} do
        def bar(x), do: x + 1
      end
      """, [mod])

      # Seed the MFA hash so we can flip it to wrong below.
      _ =
        Orchestrator.run(
          %{"subjects" => [subject("seed.subject", %{"implementation" => [mfa]}, [])]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation]
        )

      # Now mutate the head so drift fires on both tiers.
      compile_module!(fixture_dir, "no_leak7.ex", """
      defmodule #{mod_name} do
        def bar({x}), do: x + 1
      end
      """, [mod])

      subject =
        subject(
          "noleak.subject",
          %{"implementation" => [mfa, missing_mfa, missing_bare, bare]},
          []
        )

      findings =
        Orchestrator.run(%{"subjects" => [subject]},
          root: root,
          enabled_tiers: [:api_boundary, :implementation],
          commit_hashes?: false
        )

      # Sanity: the run produced at least one finding (so the assertion
      # below is non-vacuous).
      assert findings != []

      assert Enum.all?(findings, fn f ->
               not Map.has_key?(f, :inferred?) and not Map.has_key?(f, "inferred?")
             end),
             "no finding may carry inferred?; got: #{inspect(findings)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Compile a fresh source for `mods` into `fixture_dir` and reload the BEAMs.
  # Each call replaces the existing definitions for the given module list.
  defp compile_module!(fixture_dir, source_basename, source_string, mods) do
    # Purge before compile so `Code.put_compiler_option/compile_to_path` does
    # not resolve internal references against a stale .beam, and so the new
    # bytecode lands in code memory cleanly when we reload below. This is
    # the same precaution `expanded_behavior_test.exs:compile_fixture!/2`
    # takes before each recompile.
    for mod <- mods do
      :code.purge(mod)
      :code.delete(mod)
    end

    source_path = Path.join(fixture_dir, source_basename)
    File.write!(source_path, source_string)

    previous_debug_info = Code.compiler_options()[:debug_info]
    Code.put_compiler_option(:debug_info, true)

    try do
      {:ok, _mods, _warns} =
        Kernel.ParallelCompiler.compile_to_path([source_path], fixture_dir,
          return_diagnostics: true
        )
    after
      Code.put_compiler_option(:debug_info, previous_debug_info)
    end

    for mod <- mods do
      # Re-purge after compile in case ParallelCompiler reloaded any prior
      # in-memory definitions during compilation.
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end

    :ok
  end

  # Builds the parsed-subject map shape consumed by Orchestrator.run/2.
  # Mirrors the helper in OrchestratorTest so the integration tests use the
  # same shape the unit tests do.
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

  # Cross-cutting check: scenarios all assert this property
  # (specled.realized_by.binding_ref_inferred_no_leak +
  # specled.realized_by.scenario.inferred_flag_does_not_leak).
  defp refute_inferred_leak(findings) do
    leaked =
      Enum.filter(findings, fn f ->
        Map.has_key?(f, :inferred?) or Map.has_key?(f, "inferred?")
      end)

    assert leaked == [],
           "no finding may carry inferred?; leaked findings: #{inspect(leaked)}"
  end
end
