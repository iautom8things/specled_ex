defmodule SpecLedEx.Compiler.XrefTest do
  use ExUnit.Case, async: false

  alias SpecLedEx.Compiler.Xref

  describe "parse/1 (DOT → %{kind => [edge]})" do
    test "extracts edges and classifies by label kind" do
      dot = """
      digraph "xref graph" {
        "lib/a.ex"
        "lib/b.ex"
        "lib/a.ex" -> "lib/b.ex" [label="(compile)"]
        "lib/a.ex" -> "lib/c.ex" [label="(export)"]
        "lib/c.ex" -> "lib/d.ex"
      }
      """

      graph = Xref.parse(dot)

      assert graph[:compile] == [{"lib/a.ex", "lib/b.ex"}]
      assert graph[:exports] == [{"lib/a.ex", "lib/c.ex"}]
      assert graph[:runtime] == [{"lib/c.ex", "lib/d.ex"}]
    end

    test "handles both 'export' and 'exports' label spellings" do
      dot = ~S|"lib/a.ex" -> "lib/b.ex" [label="(exports)"]|
      assert Xref.parse(dot)[:exports] == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "returns empty lists for all kinds when no edges present" do
      graph = Xref.parse(~S|digraph "xref graph" {}|)
      assert graph[:compile] == []
      assert graph[:exports] == []
      assert graph[:runtime] == []
    end

    test "unknown labels fall through to :runtime" do
      dot = ~S|"lib/x.ex" -> "lib/y.ex" [label="(whatever)"]|
      assert Xref.parse(dot)[:runtime] == [{"lib/x.ex", "lib/y.ex"}]
    end
  end

  describe "scenario specled.compiler_tracer.scenario.xref_dot_parsed" do
    # Runs against the host project (specled_ex), which has many inter-file
    # edges. The sample_project fixture has a single file and thus no edges, so
    # the current Mix project is the practical target for an edge-kind check.
    @tag :integration
    test "load/1 returns a graph keyed by edge kind with at least one non-empty kind" do
      graph = Xref.load(nil)

      assert is_map(graph)
      assert Map.has_key?(graph, :compile)
      assert Map.has_key?(graph, :exports)
      assert Map.has_key?(graph, :runtime)

      any_non_empty =
        Enum.any?([:compile, :exports, :runtime], fn kind ->
          length(Map.fetch!(graph, kind)) > 0
        end)

      assert any_non_empty,
             "expected at least one non-empty edge kind, got: #{inspect(graph)}"
    end

    @tag :integration
    test "load/1 does not spawn a subprocess (Port.list is unchanged)" do
      ports_before = MapSet.new(Port.list())
      _ = Xref.load(nil)
      ports_after = MapSet.new(Port.list())

      new_ports = MapSet.difference(ports_after, ports_before)

      assert MapSet.size(new_ports) == 0,
             "Xref.load/1 must be in-process (no new Port). New ports: " <>
               inspect(MapSet.to_list(new_ports))
    end
  end
end
