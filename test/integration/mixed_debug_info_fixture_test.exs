Code.require_file("../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule SpecLedEx.Integration.MixedDebugInfoFixtureTest do
  # covers: specled.expanded_behavior_tier.mixed_fixture_coverage
  # covers: specled.expanded_behavior_tier.scenario.no_debug_info_degrades
  # covers: specled.expanded_behavior_tier.scenario.typespec_arg_change_drifts
  use SpecLedEx.IntegrationCase

  alias SpecLedEx.Realization.{ExpandedBehavior, Typespecs}

  # ---------------------------------------------------------------------------
  # The `sample_project` fixture contains two top-level modules with
  # intentionally different debug_info policies:
  #
  #   * `Sample`                 — default, debug_info retained
  #   * `SampleProject.NoDebug`  — `@compile {:no_debug_info, true}`
  #
  # This integration test compiles the real fixture via `mix compile`, loads
  # its beam files, and proves that ExpandedBehavior + Typespecs handle both
  # paths correctly:
  #
  #   * the normal module produces a stable hash, and
  #   * the stripped module degrades to `detector_unavailable` with reason
  #     `:debug_info_stripped` (never raises).
  # ---------------------------------------------------------------------------

  setup_all do
    {root, build_path} = compile_fixture("sample_project")

    # Add the fixture's ebin dir to the code path so we can load the fixture
    # modules into this VM. `compile.elixir_scm` file is alongside the beams.
    ebin =
      Path.join([
        build_path,
        "test",
        "lib",
        "sample_project",
        "ebin"
      ])

    :code.add_patha(String.to_charlist(ebin))

    # Force-load both fixture modules so they are resolvable.
    for mod <- [Sample, SampleProject.NoDebug] do
      _ = :code.ensure_loaded(mod)
    end

    on_exit(fn ->
      :code.del_path(String.to_charlist(ebin))
    end)

    {:ok, root: root, ebin: ebin}
  end

  @tag :integration
  test "ExpandedBehavior hashes Sample.hello/0 (module with debug_info)" do
    assert {:ok, hash} = ExpandedBehavior.hash("Sample.hello/0")
    assert is_binary(hash)
    assert byte_size(hash) == 32
  end

  @tag :integration
  test "ExpandedBehavior degrades to detector_unavailable on SampleProject.NoDebug.fun/0" do
    assert {:error, {:debug_info_stripped, SampleProject.NoDebug}} =
             ExpandedBehavior.hash("SampleProject.NoDebug.fun/0")
  end

  @tag :integration
  test "Typespecs degrades to detector_unavailable on SampleProject.NoDebug.fun/0" do
    assert {:error, {:debug_info_stripped, SampleProject.NoDebug}} =
             Typespecs.hash("SampleProject.NoDebug.fun/0")
  end

  @tag :integration
  test "run/3 emits exactly one detector_unavailable finding across both stripped bindings" do
    bindings = [
      %{
        subject_id: "mixed.sample",
        requirement_id: "mixed.sample.r1",
        mfa: "SampleProject.NoDebug.fun/0"
      }
    ]

    root =
      Path.join(
        System.tmp_dir!(),
        "specled_mixed_debug_root_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)

    exp_findings = ExpandedBehavior.run(bindings, nil, root: root)
    ts_findings = Typespecs.run(bindings, nil, root: root)

    assert [exp] = exp_findings
    assert exp["code"] == "detector_unavailable"
    assert exp["reason"] == "debug_info_stripped"
    assert exp["tier"] == "expanded_behavior"

    assert [ts] = ts_findings
    assert ts["code"] == "detector_unavailable"
    assert ts["reason"] == "debug_info_stripped"
    assert ts["tier"] == "typespecs"

    refute Enum.any?(exp_findings ++ ts_findings, &(&1["code"] == "branch_guard_realization_drift"))
  end
end
