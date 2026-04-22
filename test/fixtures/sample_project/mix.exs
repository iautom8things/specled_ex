defmodule SampleProject.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_project,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      elixirc_options: [tracers: tracers()],
      deps: []
    ]
  end

  def application, do: []

  # Registers `tracers: [SpecLedEx.Compiler.Tracer]` when the parent's tracer
  # module is loadable (typically via ERL_LIBS from the parent's _build). When
  # unavailable, compile proceeds with no tracer — the fixture is still usable
  # for integration tests that don't depend on the MFA manifest.
  defp tracers do
    if Code.ensure_loaded?(SpecLedEx.Compiler.Tracer) do
      [SpecLedEx.Compiler.Tracer]
    else
      []
    end
  end
end
