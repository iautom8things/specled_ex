defmodule SpecLedEx.Compiler.Xref do
  @moduledoc """
  In-process file-level call graph derived from `mix xref graph --format dot`.

  `load/1` invokes `Mix.Task.run("xref", ["graph", "--format", "dot", "--output", "-"])`
  in-process — it does NOT shell out to a subprocess — captures the DOT output via
  a group-leader swap, and parses the edges into a map keyed by edge kind:

      %{
        compile: [{from_file, to_file}, ...],
        exports: [{from_file, to_file}, ...],
        runtime: [{from_file, to_file}, ...]
      }

  The coarse file/module graph is the seam for compile/exports/runtime
  classification used by the `implementation`, `use`, and `expanded_behavior`
  tiers. MFA-level call edges come from `SpecLedEx.Compiler.Tracer` and a
  separate ETF side-manifest; see that module and
  `specled.decision.custom_compile_tracer`.

  The `--format json` output does NOT exist in Elixir 1.18 (verified against the
  supported formats `pretty|plain|stats|cycles|dot`); any attempt to add a JSON
  code path is explicitly out of scope.
  """

  @kinds [:compile, :exports, :runtime]

  @type edge :: {String.t(), String.t()}
  @type graph :: %{optional(:compile | :exports | :runtime) => [edge()]}

  @doc """
  Runs `mix xref graph --format dot --output -` in-process for the current
  `Mix.Project` and returns the parsed graph keyed by edge kind.

  The `_context` argument is accepted for symmetry with other compile-time
  loaders but is not consulted — `mix xref` runs against the currently scoped
  Mix project. Callers that need to target a different project should wrap the
  call in `Mix.Project.in_project/4`.

  Returns a map with `:compile`, `:exports`, and `:runtime` keys; each value is
  a (possibly empty) list of `{from_file, to_file}` tuples.
  """
  @spec load(term()) :: graph()
  def load(_context \\ nil) do
    dot = capture_xref_dot()
    parse(dot)
  end

  @doc """
  Parses a DOT string (as emitted by `mix xref graph --format dot`) into a map
  keyed by edge kind. Exposed primarily for testing.
  """
  @spec parse(String.t()) :: graph()
  def parse(dot) when is_binary(dot) do
    empty = Map.new(@kinds, fn kind -> {kind, []} end)

    Regex.scan(~r/"([^"]+)"\s*->\s*"([^"]+)"(?:\s*\[label="\(([^)]+)\)"\])?/, dot)
    |> Enum.reduce(empty, fn match, acc ->
      {from, to, kind} = classify(match)
      Map.update(acc, kind, [{from, to}], &[{from, to} | &1])
    end)
    |> Map.new(fn {k, edges} -> {k, Enum.reverse(edges)} end)
  end

  defp classify([_full, from, to, raw_kind]), do: {from, to, normalize_kind(raw_kind)}
  defp classify([_full, from, to]), do: {from, to, :runtime}

  defp normalize_kind("compile"), do: :compile
  defp normalize_kind("export"), do: :exports
  defp normalize_kind("exports"), do: :exports
  defp normalize_kind("runtime"), do: :runtime
  defp normalize_kind(_other), do: :runtime

  defp capture_xref_dot do
    {:ok, io} = StringIO.open("")
    original_gl = Process.group_leader()

    try do
      Process.group_leader(self(), io)
      Mix.Task.reenable("xref")
      Mix.Task.run("xref", ["graph", "--format", "dot", "--output", "-"])
    after
      Process.group_leader(self(), original_gl)
    end

    {_input, output} = StringIO.contents(io)
    StringIO.close(io)
    output
  end
end
