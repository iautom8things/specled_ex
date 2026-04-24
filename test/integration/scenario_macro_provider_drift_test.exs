defmodule SpecLedEx.Integration.ScenarioMacroProviderDriftTest do
  # covers: specled.use_tier.scenario_macro_provider_drift
  # covers: specled.use_tier.scenario.provider_drift_one_finding
  use ExUnit.Case, async: false
  @moduletag spec: ["specled.use_tier.scenario_macro_provider_drift"]

  @moduletag :integration

  alias SpecLedEx.Realization.{Drift, HashStore, Use}

  # ---------------------------------------------------------------------------
  # Scenario 4 (the gating criterion of specled.use_tier):
  #
  #   Given a macro provider P and three consumers C1, C2, C3
  #   And   a committed use-tier hash for P
  #   When  the provider's __using__/1 body changes
  #   Then  exactly one branch_guard_realization_drift finding names P as
  #         the root cause, with consumers_affected = 3
  #   And   no drift finding names C1, C2, or C3 — those are absorbed by the
  #         provider's root_cause via Drift.dedupe/2
  # ---------------------------------------------------------------------------

  @provider_baseline """
  defmodule SpecLedEx.MacroScenario.Provider do
    defmacro __using__(_opts) do
      quote do
        def __from_provider__, do: :v1
      end
    end
  end
  """

  @provider_changed """
  defmodule SpecLedEx.MacroScenario.Provider do
    defmacro __using__(_opts) do
      quote do
        def __from_provider__, do: :v2_changed
      end
    end
  end
  """

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_macro_drift_root_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp compile_fixture!(source, tag) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_macro_drift_#{tag}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    source_path = Path.join(tmp_dir, "fixture_#{tag}.ex")
    File.write!(source_path, source)

    previous = Code.compiler_options()[:debug_info]
    Code.put_compiler_option(:debug_info, true)

    try do
      {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir)
    after
      Code.put_compiler_option(:debug_info, previous)
    end

    :code.add_patha(String.to_charlist(tmp_dir))
    tmp_dir
  end

  defp reload!(mods) do
    for mod <- mods do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end
  end

  test "provider expansion change yields one root-cause finding naming the provider", %{
    root: root
  } do
    # Pretend tracer captured 3 consumers using the provider.
    edges = %{
      {SpecLedEx.MacroScenario.C1, :__MODULE__, 0} =>
        [{SpecLedEx.MacroScenario.Provider, :__using__, 1}],
      {SpecLedEx.MacroScenario.C2, :__MODULE__, 0} =>
        [{SpecLedEx.MacroScenario.Provider, :__using__, 1}],
      {SpecLedEx.MacroScenario.C3, :__MODULE__, 0} =>
        [{SpecLedEx.MacroScenario.Provider, :__using__, 1}]
    }

    # Step 1 — commit baseline use-tier hash for P.
    dir_a = compile_fixture!(@provider_baseline, "scenario_baseline")
    reload!([SpecLedEx.MacroScenario.Provider])

    {:ok, baseline_hash} =
      Use.hash("SpecLedEx.MacroScenario.Provider", tracer_edges: edges)

    :ok =
      HashStore.write(root, %{
        "use" => %{
          "SpecLedEx.MacroScenario.Provider" => %{
            "hash" => Base.encode16(baseline_hash, case: :lower),
            "hasher_version" => HashStore.hasher_version()
          }
        }
      })

    # Step 2 — branch flips the provider expansion.
    dir_b = compile_fixture!(@provider_changed, "scenario_changed")
    reload!([SpecLedEx.MacroScenario.Provider])

    on_exit(fn ->
      :code.del_path(String.to_charlist(dir_a))
      :code.del_path(String.to_charlist(dir_b))
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_b)
    end)

    bindings = [
      %{
        subject_id: "macro_provider_subj",
        requirement_id: "macro_provider_subj.r1",
        mfa: "SpecLedEx.MacroScenario.Provider"
      }
    ]

    use_findings = Use.run(bindings, nil, root: root, tracer_edges: edges)

    # Use.run emits one drift delta on the provider — pre-dedupe.
    assert [provider_delta] = use_findings
    assert provider_delta.tier == :use
    assert provider_delta.subject_id == "macro_provider_subj"

    expected_consumers =
      [SpecLedEx.MacroScenario.C1, SpecLedEx.MacroScenario.C2, SpecLedEx.MacroScenario.C3]

    assert provider_delta.consumers == expected_consumers

    # Simulate the consumers' expanded_behavior drift findings — each consumer
    # subject also reported drift because the provider's macro changed their
    # post-expansion AST. These are exactly what root-cause dedup must absorb.
    consumer_deltas =
      for c <- ["c1_subj", "c2_subj", "c3_subj"] do
        %{
          subject_id: c,
          code: :branch_guard_realization_drift,
          tier: :expanded_behavior
        }
      end

    deltas = consumer_deltas ++ [provider_delta]

    pred = fn from, to ->
      from in ["c1_subj", "c2_subj", "c3_subj"] and to == "macro_provider_subj"
    end

    deduped = Drift.dedupe(deltas, pred)

    # Exactly one finding remains; it names the provider as root cause.
    assert [final] = deduped
    assert final.subject_id == "macro_provider_subj"

    # Zero findings name C1, C2, or C3 directly.
    refute Enum.any?(deduped, fn d ->
             d.subject_id in ["c1_subj", "c2_subj", "c3_subj"]
           end)

    # Per-spec root_cause shape.
    assert final.root_cause.tier == :use
    assert final.root_cause.provider == {SpecLedEx.MacroScenario.Provider, :__using__, 1}
    assert final.root_cause.consumers_affected == 3
    assert final.root_cause.consumers == expected_consumers

    # 8-char hex prefixes for hash diff (specled.use_tier.hash_prefix_length).
    assert String.length(final.root_cause.hash_prefix_before) == 8
    assert String.length(final.root_cause.hash_prefix_after) == 8
    refute final.root_cause.hash_prefix_before == final.root_cause.hash_prefix_after,
           "hash prefixes must differ when the provider expansion changes"
  end
end
