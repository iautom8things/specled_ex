defmodule SpecLedEx.Compiler.TracerBootstrapTest do
  # async: false — the bootstrap flips the global :tracers compiler option while
  # it compiles, so it must not run alongside anything else that compiles.
  use ExUnit.Case, async: false

  # Tagged per-test rather than via @moduletag: the failed-compile case covers a
  # different requirement id, and an @tag would silently REPLACE a moduletag value
  # for the same key rather than add to it.

  # covers: specled.compiler_tracer.bootstrap_rebuilds_on_content_change
  # covers: specled.compiler_tracer.bootstrap_digest_recorded_after_success

  setup do
    # Cross-VM-unique root: this suite can run nested inside a `mix spec.check`
    # merged run, and a VM-local counter would let one run's cleanup delete
    # another's fixtures.
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_tracer_bootstrap_#{SpecLedEx.TempName.cross_vm_suffix()}"
      )

    ebin = Path.join(root, "ebin")
    src = Path.join(root, "probe_source.ex")
    File.mkdir_p!(ebin)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, ebin: ebin, src: src}
  end

  # Unique per call, so compiling here can never collide with a module this VM
  # has already loaded.
  defp probe_module, do: "SpecLedEx.BootstrapProbe#{System.unique_integer([:positive])}"

  defp write_source!(src, module, marker) do
    File.write!(src, """
    defmodule #{module} do
      def marker, do: #{inspect(marker)}
    end
    """)
  end

  defp bootstrap(src, ebin, module),
    do: SpecLedEx.MixProject.compile_tracer_if_stale!(src, ebin, "Elixir." <> module)

  defp beam_path(ebin, module), do: Path.join(ebin, "Elixir." <> module <> ".beam")
  defp digest_path(ebin, module), do: Path.join(ebin, "Elixir." <> module <> ".srcdigest")
  defp posix_mtime(path), do: File.stat!(path, time: :posix).mtime

  describe "compile_tracer_if_stale!/3" do
    @tag spec: ["specled.compiler_tracer.bootstrap_rebuilds_on_content_change"]
    test "compiles when no artifact exists yet", %{ebin: ebin, src: src} do
      module = probe_module()
      write_source!(src, module, "first")

      assert bootstrap(src, ebin, module) == :compiled
      assert File.regular?(beam_path(ebin, module))
      assert File.read!(digest_path(ebin, module)) == SpecLedEx.MixProject.source_digest(src)
    end

    @tag spec: ["specled.compiler_tracer.bootstrap_rebuilds_on_content_change"]
    test "skips recompiling when the source content is unchanged", %{ebin: ebin, src: src} do
      module = probe_module()
      write_source!(src, module, "first")

      assert bootstrap(src, ebin, module) == :compiled
      assert bootstrap(src, ebin, module) == :fresh
    end

    # THE REGRESSION TEST for specled_-pr6. Against the previous implementation --
    # `File.stat!(src).mtime > File.stat!(beam).mtime` -- this fails: with the two
    # mtimes held equal the comparison is false, the mutated artifact is judged
    # fresh, and no rebuild happens. Content-addressed staleness is what fixes it.
    @tag spec: ["specled.compiler_tracer.bootstrap_rebuilds_on_content_change"]
    test "rebuilds on a content change even when source and beam mtimes are IDENTICAL",
         %{ebin: ebin, src: src} do
      module = probe_module()
      write_source!(src, module, "original")
      assert bootstrap(src, ebin, module) == :compiled

      beam = beam_path(ebin, module)
      digest_before = SpecLedEx.MixProject.source_digest(src)

      # Mutate, then force src and beam to share one mtime -- exactly the state a
      # same-second edit-compile-revert cycle leaves behind.
      write_source!(src, module, "mutated")
      shared = posix_mtime(beam)
      File.touch!(src, shared)
      File.touch!(beam, shared)

      assert posix_mtime(src) == posix_mtime(beam),
             "precondition: mtimes must be equal for this test to exercise the defect"

      digest_after = SpecLedEx.MixProject.source_digest(src)
      refute digest_after == digest_before, "precondition: the mutation must change the digest"

      assert bootstrap(src, ebin, module) == :compiled,
             "a content change must force a rebuild even when mtimes are identical"

      assert File.read!(digest_path(ebin, module)) == digest_after
    end

    @tag spec: ["specled.compiler_tracer.bootstrap_rebuilds_on_content_change"]
    test "rebuilds when the source is OLDER than the beam but its content differs",
         %{ebin: ebin, src: src} do
      module = probe_module()
      write_source!(src, module, "original")
      assert bootstrap(src, ebin, module) == :compiled

      write_source!(src, module, "mutated")
      # Backdate the source well behind the beam. An mtime comparison reads this
      # as fresh; content addressing does not consider ordering at all.
      File.touch!(src, posix_mtime(beam_path(ebin, module)) - 60)

      assert bootstrap(src, ebin, module) == :compiled
    end

    @tag spec: ["specled.compiler_tracer.bootstrap_digest_recorded_after_success"]
    test "a failed compile records no digest, so the artifact stays stale",
         %{ebin: ebin, src: src} do
      module = probe_module()
      File.write!(src, "defmodule #{module} do\n  this is not valid elixir(\nend\n")

      assert catch_error(bootstrap(src, ebin, module))
      refute File.exists?(digest_path(ebin, module))

      # Once the source is valid the next bootstrap still recompiles, rather than
      # having been marked fresh by the failed attempt.
      write_source!(src, module, "recovered")
      assert bootstrap(src, ebin, module) == :compiled
    end
  end
end
