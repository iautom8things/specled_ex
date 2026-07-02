defmodule SpecLedEx.Compiler.Context do
  @moduledoc """
  Shared DI struct carrying the compile-time inputs every realization orchestrator
  needs.

  Orchestrators under `SpecLedEx.Realization.*` accept a `%Context{}` as a positional
  argument rather than reaching into `Mix.env/0` or `Mix.Project.config/0`. Tests
  construct a context with fixture-pointing fields; production calls
  `from_mix_project/1` at the mix-task entry point — the only Context function
  that consults Mix globals. `load/1` stays Mix-free.

  Fields:

    * `:manifest` — a parsed compile manifest (see `SpecLedEx.Compiler.Manifest`)
    * `:xref_graph` — the xref call graph (S3a wiring; may be nil in S2)
    * `:tracer_table` — an ETS table ref populated by a tracer (S3a)
    * `:compile_path` — the directory containing compiled `.beam` artifacts
  """

  alias SpecLedEx.Compiler.Manifest

  defstruct manifest: nil, xref_graph: nil, tracer_table: nil, compile_path: nil

  @type t :: %__MODULE__{
          manifest: term(),
          xref_graph: term(),
          tracer_table: term(),
          compile_path: Path.t() | nil
        }

  @doc """
  Builds a `%Context{}` from explicit options.

  Does not consult `Mix.env/0` or `Mix.Project.config/0`. The caller supplies every
  input; defaults are the caller's responsibility.

  Options:

    * `:app` — the app atom (required for computing the compile path)
    * `:env` — the mix env atom (e.g. `:test`)
    * `:build_path` — the root of `_build`
    * `:compile_path` — overrides the derived compile path
    * `:manifest_path` — overrides the derived manifest path
    * `:xref_graph`, `:tracer_table` — pass-through, optional
  """
  @spec load(keyword()) :: t()
  def load(opts) do
    app = Keyword.fetch!(opts, :app)
    env = Keyword.fetch!(opts, :env)
    build_path = Keyword.fetch!(opts, :build_path)

    compile_path =
      opts[:compile_path] ||
        Path.join([build_path, Atom.to_string(env), "lib", Atom.to_string(app), "ebin"])

    # The compile manifest lives in the app dir's `.mix/`, a *sibling* of
    # `ebin` — derived via dirname so an explicit `compile_path:` override
    # still finds its own sibling.
    manifest_path =
      opts[:manifest_path] ||
        Path.join([Path.dirname(compile_path), ".mix", "compile.elixir"])

    manifest = Manifest.load(manifest_path)

    %__MODULE__{
      manifest: manifest,
      xref_graph: opts[:xref_graph],
      tracer_table: opts[:tracer_table],
      compile_path: compile_path
    }
  end

  @doc """
  Builds a `%Context{}` from the current Mix project — the production
  entry-point constructor, and the only Context function that consults Mix
  globals; `load/1` stays Mix-free. Keyword `opts` override any derived
  value and are passed through to `load/1`.
  """
  @spec from_mix_project(keyword()) :: t()
  def from_mix_project(opts \\ []) do
    [
      app: Mix.Project.config()[:app],
      env: Mix.env(),
      build_path: Path.dirname(Mix.Project.build_path()),
      compile_path: Mix.Project.compile_path(),
      manifest_path: Path.join(Mix.Project.manifest_path(), "compile.elixir")
    ]
    |> Keyword.merge(opts)
    |> load()
  end
end
