defmodule SpecLedEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :spec_led_ex,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 83]],
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      elixirc_paths: elixirc_paths(Mix.env()),
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
  defp elixirc_paths(:test), do: lib_paths() ++ ["test/test_support"]
  defp elixirc_paths(_), do: lib_paths()

  defp lib_paths do
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
    ebin = Path.join([Mix.Project.build_path(), "lib", "spec_led_ex", "ebin"])

    compile_tracer_if_stale!(
      Path.expand(@tracer_source),
      ebin,
      "Elixir.SpecLedEx.Compiler.Tracer"
    )

    Code.prepend_path(ebin)
    Code.ensure_loaded(SpecLedEx.Compiler.Tracer)
  end

  @doc """
  Compiles `src` into `ebin` when the artifact does not match the source's CONTENT.

  Staleness is decided by comparing a SHA-256 digest of the source against a
  digest recorded beside the beam on the last successful compile — never by
  comparing mtimes. An mtime comparison is unsound here: `File.stat!/1` mtimes
  have one-second granularity, so an edit (or a `git checkout` revert) landing in
  the same second as the previous compile leaves `src.mtime > beam.mtime` false
  and the stale artifact is treated as fresh indefinitely. That failure mode is
  unrecoverable by ordinary means, because `@tracer_source` is excluded from
  `elixirc_paths/1` and so `mix compile --force` never rebuilds it — the symptom
  is a pristine tree running mutated code.

  Public and parameterised only so the regression test can drive it against
  scratch paths; production callers use `bootstrap_tracer!/0`.
  """
  def compile_tracer_if_stale!(src, ebin, module_basename) do
    beam = Path.join(ebin, module_basename <> ".beam")
    digest_path = Path.join(ebin, module_basename <> ".srcdigest")
    digest = source_digest(src)

    if tracer_stale?(beam, digest_path, digest) do
      File.mkdir_p!(ebin)
      prev = Code.get_compiler_option(:tracers) || []

      try do
        Code.put_compiler_option(:tracers, [])

        {:ok, _modules, _diagnostics} =
          Kernel.ParallelCompiler.compile_to_path([src], ebin, return_diagnostics: true)
      after
        Code.put_compiler_option(:tracers, prev)
      end

      # Recorded only after a successful compile, so a failed compile leaves the
      # artifact stale rather than marking it fresh.
      File.write!(digest_path, digest)
      :compiled
    else
      :fresh
    end
  end

  @doc """
  Digest keying the compiled artifact to both the source CONTENT and the
  toolchain that produced it.

  The toolchain is part of the key because a beam is only loadable by a
  compatible OTP: compiling under OTP 28 and then running the OTP 26 matrix leg
  in the same worktree leaves an artifact the older child BEAM cannot load, so
  fixture subprocess compiles silently proceed with no tracer at all and fail
  with signatures that mimic real regressions. Content alone cannot distinguish
  that case — the source is byte-identical across legs — so the version pair is
  mixed in and a leg switch rebuilds automatically.
  """
  def source_digest(src) do
    payload = [File.read!(src), "\n", System.otp_release(), "/", System.version()]
    :crypto.hash(:sha256, IO.iodata_to_binary(payload)) |> Base.encode16(case: :lower)
  end

  defp tracer_stale?(beam, digest_path, digest) do
    not File.regular?(beam) or File.read(digest_path) != {:ok, digest}
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :yaml_elixir, :jason]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:zoi, "~> 0.17"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:earmark, "~> 1.4"}
    ]
  end
end
