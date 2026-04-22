defmodule SpecLedEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :spec_led_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 90]],
      elixirc_paths: elixirc_paths(),
      elixirc_options: [tracers: tracers()],
      deps: deps()
    ]
  end

  @tracer_source "lib/specled_ex/compiler/tracer.ex"

  # Exclude tracer.ex from the main elixir compile. A module cannot trace its
  # own recompilation — the parallel compiler holds a lock on a module that is
  # in-flight, so any trace event fires before the module is reloaded and
  # `Tracer.trace/2` is seen as "not available". We therefore compile tracer.ex
  # on its own (see `bootstrap_tracer!/0`) into the project's ebin before Mix's
  # main compile starts, and we keep Mix's elixirc compiler out of that file.
  defp elixirc_paths do
    Path.wildcard("lib/**/*.ex") |> Enum.reject(&(&1 == @tracer_source))
  end

  # Registers `tracers: [SpecLedEx.Compiler.Tracer]` once the tracer beam is
  # loadable from the project ebin. `bootstrap_tracer!/0` guarantees that
  # state before this function returns. Set SPECLED_DISABLE_TRACER=1 to skip.
  defp tracers do
    if System.get_env("SPECLED_DISABLE_TRACER") do
      []
    else
      bootstrap_tracer!()
      [SpecLedEx.Compiler.Tracer]
    end
  end

  defp bootstrap_tracer! do
    ebin = Path.expand("_build/#{Mix.env()}/lib/spec_led_ex/ebin")
    src = Path.expand(@tracer_source)
    beam = Path.join(ebin, "Elixir.SpecLedEx.Compiler.Tracer.beam")

    stale? =
      not File.regular?(beam) or
        File.stat!(src).mtime > File.stat!(beam).mtime

    if stale? do
      File.mkdir_p!(ebin)
      prev = Code.get_compiler_option(:tracers) || []

      try do
        Code.put_compiler_option(:tracers, [])
        {:ok, _modules, _warnings} = Kernel.ParallelCompiler.compile_to_path([src], ebin)
      after
        Code.put_compiler_option(:tracers, prev)
      end
    end

    Code.ensure_loaded(SpecLedEx.Compiler.Tracer)
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:zoi, "~> 0.17"},
      {:stream_data, "~> 1.0", only: [:test, :dev]}
    ]
  end
end
