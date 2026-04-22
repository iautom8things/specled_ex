defmodule SpecLedEx.Integration.ScenarioRefactorStableTest do
  # covers: specled.implementation_tier.scenario.refactor_does_not_drift
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SpecLedEx.Realization.{HashStore, Implementation}

  # ---------------------------------------------------------------------------
  # Scenario 1 (the gating criterion of specled.implementation_tier):
  #
  #   Given a subject with an implementation closure of three MFAs
  #   And   a committed implementation hash for that subject
  #   When  a branch renames local variables and reflows function bodies
  #   Then  no branch_guard_realization_drift finding is emitted for that subject
  #
  # We simulate a "branch" by recompiling the fixture source with cosmetic
  # edits — renamed locals, reordered whitespace, reordered independent
  # function heads — and asserting that the impl hash does not move.
  # ---------------------------------------------------------------------------

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_refactor_stable_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    root =
      Path.join(
        System.tmp_dir!(),
        "specled_refactor_stable_root_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))

    on_exit(fn ->
      :code.del_path(String.to_charlist(tmp_dir))
      File.rm_rf!(tmp_dir)
      File.rm_rf!(root)
    end)

    {:ok, tmp_dir: tmp_dir, root: root}
  end

  defp compile_fixture!(tmp_dir, source) do
    source_path = Path.join(tmp_dir, "scenario_fixture.ex")
    File.write!(source_path, source)

    {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir)
    :code.add_patha(String.to_charlist(tmp_dir))

    for mod <- [
          SpecLedEx.ScenarioFixture.A,
          SpecLedEx.ScenarioFixture.B
        ] do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end

    :ok
  end

  defp fixture_world do
    # Subject A owns a 3-MFA closure: A.run/1 -> A.step1/1 -> A.step2/1.
    # B.noise/0 is unrelated and in another subject so it's cleanly bounded.
    subject_a = %{
      id: "A",
      surface: [],
      impl_bindings: ["SpecLedEx.ScenarioFixture.A.run/1"]
    }

    subject_b = %{
      id: "B",
      surface: [],
      impl_bindings: ["SpecLedEx.ScenarioFixture.B.noise/0"]
    }

    edges = %{
      {SpecLedEx.ScenarioFixture.A, :run, 1} => [{SpecLedEx.ScenarioFixture.A, :step1, 1}],
      {SpecLedEx.ScenarioFixture.A, :step1, 1} => [{SpecLedEx.ScenarioFixture.A, :step2, 1}],
      {SpecLedEx.ScenarioFixture.A, :step2, 1} => []
    }

    in_project? = fn mod ->
      mod in [SpecLedEx.ScenarioFixture.A, SpecLedEx.ScenarioFixture.B]
    end

    %{
      subjects: [subject_a, subject_b],
      tracer_edges: edges,
      in_project?: in_project?
    }
  end

  @main_src """
  defmodule SpecLedEx.ScenarioFixture.A do
    def run(x) do
      y = SpecLedEx.ScenarioFixture.A.step1(x)
      y + 1
    end

    def step1(a) do
      b = SpecLedEx.ScenarioFixture.A.step2(a)
      b * 2
    end

    def step2(n), do: n + 3
  end

  defmodule SpecLedEx.ScenarioFixture.B do
    def noise, do: :ok
  end
  """

  @refactored_src """
  defmodule SpecLedEx.ScenarioFixture.A do
    # Cosmetic refactor: renamed locals, whitespace shifts, body reflow.
    # Semantics are unchanged.

    def run(input) do
      result =
        SpecLedEx.ScenarioFixture.A.step1(input)

      result + 1
    end

    def step1(value) do
      next =
        SpecLedEx.ScenarioFixture.A.step2(value)

      next * 2
    end

    def step2(count), do: count + 3
  end

  defmodule SpecLedEx.ScenarioFixture.B do
    def noise, do: :ok
  end
  """

  test "cosmetic refactor inside closure produces no drift finding", %{
    tmp_dir: tmp_dir,
    root: root
  } do
    # Commit the original impl hash.
    :ok = compile_fixture!(tmp_dir, @main_src)
    world = fixture_world()
    subject_a = hd(world.subjects)

    {:ok, committed} = Implementation.hash_for_subject(subject_a, world)

    :ok =
      HashStore.write(root, %{
        "implementation" => %{
          "A" => %{
            "hash" => Base.encode16(committed, case: :lower),
            "hasher_version" => HashStore.hasher_version()
          }
        }
      })

    # "Branch": recompile with cosmetic edits, same 3-MFA closure.
    :ok = compile_fixture!(tmp_dir, @refactored_src)

    findings = Implementation.run([subject_a], world, nil, root: root)

    drift =
      Enum.find(findings, fn f ->
        f["code"] == "branch_guard_realization_drift" and f["subject_id"] == "A"
      end)

    assert drift == nil,
           "expected no drift finding for cosmetic refactor, got: #{inspect(findings)}"
  end
end
