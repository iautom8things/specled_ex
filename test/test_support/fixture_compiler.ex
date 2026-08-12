defmodule SpecLedEx.FixtureCompiler do
  @moduledoc """
  Compiles runtime test fixtures with an explicit `:debug_info` choice,
  restoring the previous compiler option afterwards.

  Mix's test task disables `:debug_info` for runtime compilation in the test
  BEAM (test files do not need it), and it re-disables the option after
  `test_helper.exs` runs, so a global flip there cannot stick. Fixture modules
  that realization tests resolve through `Binding.resolve/2` DO need it:
  production `mix spec.check` resolves mix-compiled beams that carry
  debug_info, so a fixture compiled without it silently exercises the
  source-AST fallback instead of the beam path — indistinguishable until
  resolution-path provenance landed (specled_-n5q.1).

  The `@compile {:no_debug_info, true}` module attribute is INERT for this
  purpose — probed empirically during specled_-n5q.1: the emitted chunk is
  governed by the compiler option alone, with or without the attribute.
  Fixtures that exercise the stripped-debug degrade therefore use the
  explicit `compile_to_path_without_debug_info/2` sibling rather than an
  attribute or the ambient mix-test default.

  > #### Callers must be `async: false` {: .warning}
  >
  > Both entry points flip a GLOBAL compiler option (`Code.put_compiler_option/2`)
  > for the duration of the compile and restore it afterwards. A concurrently
  > running async test that compiles a fixture in that window observes the
  > wrong `:debug_info` setting and silently resolves through the other path —
  > exactly the failure this module exists to eliminate. Test modules using
  > this compiler must declare `async: false`.
  """

  @doc """
  `Kernel.ParallelCompiler.compile_to_path/3` with `:debug_info` forced ON
  for the duration of the compile. Returns the ParallelCompiler result.
  """
  def compile_to_path_with_debug_info(files, dest) do
    compile_with_option(files, dest, true)
  end

  @doc """
  `Kernel.ParallelCompiler.compile_to_path/3` with `:debug_info` forced OFF —
  for fixtures exercising the stripped-debug degrade path, independent of the
  ambient compiler default.
  """
  def compile_to_path_without_debug_info(files, dest) do
    compile_with_option(files, dest, false)
  end

  defp compile_with_option(files, dest, debug_info?) do
    prev = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, debug_info?)

    try do
      Kernel.ParallelCompiler.compile_to_path(files, dest, return_diagnostics: true)
    after
      Code.put_compiler_option(:debug_info, prev)
    end
  end
end
