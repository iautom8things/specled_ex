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
    @tag spec: "specled.coverage_capture.case_template"
    test "use SpecLedEx.Case forwards ExUnit opts and runs injected boundary setup" do
      parent_lib = Path.expand("_build/#{Mix.env()}/lib")

      script = """
      ExUnit.start()

      defmodule CaseTemplateProbeTest do
        use SpecLedEx.Case, async: true

        setup_all do
          tid = :ets.new(:case_template_boundary, [:public, :set])

          snapshots = [
            %{CaseTemplateProbe => [{10, 0}]},
            %{CaseTemplateProbe => [{10, 1}]}
          ]

          {:ok, agent} = Agent.start(fn -> snapshots end)

          snapshot_fn = fn _modules ->
            Agent.get_and_update(agent, fn
              [snapshot | rest] -> {snapshot, rest}
              [] -> {%{}, []}
            end)
          end

          Application.put_env(:specled_ex, :spec_cover_run,
            boundary_table: tid,
            snapshot_fn: snapshot_fn,
            modules_fn: fn -> [CaseTemplateProbe] end
          )

          on_exit(fn ->
            Application.delete_env(:specled_ex, :spec_cover_run)

            if Process.alive?(agent) do
              Agent.stop(agent)
            end
          end)

          {:ok, snapshot_agent: agent}
        end

        test "adopter receives opts and boundary setup", context do
          assert context.async == true
          assert function_exported?(__MODULE__, :__ex_unit__, 0)
          assert Agent.get(context.snapshot_agent, &length/1) == 1
        end
      end
      """

      {output, status} =
        System.cmd("elixir", ["-e", script],
          env: [{"ERL_LIBS", parent_lib}],
          stderr_to_stdout: true
        )

      assert status == 0,
             "expected child-BEAM SpecLedEx.Case adopter to pass, got #{status}.\nOutput:\n#{output}"
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
      # (after on_exit callbacks complete). Boundary.tail/2 tolerates a gone
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
      assert Agent.get(agent, &length/1) == 1
    end
  end
end
