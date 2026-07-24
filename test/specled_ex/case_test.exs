defmodule SpecLedEx.CaseTest do
  # Shares Application env arming seam with BoundaryTest — must not race.
  use ExUnit.Case, async: false

  @moduletag spec: [
               "specled.coverage_capture.case_template",
               "specled.coverage_capture.boundary_noop_unarmed"
             ]

  setup do
    on_exit(fn -> Application.delete_env(:specled_ex, :spec_cover_run) end)
    :ok
  end

  describe "SpecLedEx.Case (production template in lib/specled_ex/case.ex)" do
    test "production source is an ExUnit.CaseTemplate injecting per_test_boundary" do
      # Host-suite tests redefine SpecLedEx.Case via test_support/specled_ex_case.ex
      # (workspace fixture helper). The shippable template lives at
      # lib/specled_ex/case.ex and is what child-BEAM fixtures load from the
      # parent ebin — assert its shape from source so the host redefine cannot
      # shadow the contract.
      source = File.read!("lib/specled_ex/case.ex")

      assert source =~ "defmodule SpecLedEx.Case do"
      assert source =~ "use ExUnit.CaseTemplate"
      assert source =~ "setup {SpecLedEx.Coverage, :per_test_boundary}"
      assert function_exported?(SpecLedEx.Coverage, :per_test_boundary, 1)
    end

    @tag spec: "specled.coverage_capture.boundary_noop_unarmed"
    test "SpecLedEx.Case is a no-op under plain mix test" do
      # Named discoverability test: the setup line Case injects must be a pure
      # no-op when the arming seam is unset (plain mix test).
      Application.delete_env(:specled_ex, :spec_cover_run)

      assert :ok =
               SpecLedEx.Coverage.per_test_boundary(%{
                 module: SpecLedEx.CaseTest,
                 test: :"test SpecLedEx.Case is a no-op under plain mix test"
               })
    end

    test "per_test_boundary returns :ok when armed with a boundary_table" do
      # ETS table is owned by this test process and auto-drops when it exits
      # (after on_exit callbacks complete). Boundary.tail/3 tolerates a gone
      # table so the registered on_exit does not raise in the host suite.
      tid = :ets.new(:anon, [:public, :set])

      snapshots = [
        %{Mod => [{1, 0}]},
        %{Mod => [{1, 1}]}
      ]

      agent = start_supervised!({Agent, fn -> snapshots end})

      snapshot_fn = fn _ ->
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {%{}, []}
        end)
      end

      Application.put_env(:specled_ex, :spec_cover_run,
        boundary_table: tid,
        snapshot_fn: snapshot_fn,
        modules_fn: fn -> [Mod] end
      )

      context = %{module: ArmedCaseTest, test: :"test hooked"}

      # Would fail if the public setup callback crashed when armed.
      assert :ok = SpecLedEx.Coverage.per_test_boundary(context)
    end
  end
end
