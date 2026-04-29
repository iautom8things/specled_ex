defmodule SpecLedEx.Realization.ExpandedBehaviorTest do
  # covers: specled.expanded_behavior_tier.reads_beam_debug_info
  # covers: specled.expanded_behavior_tier.hash_stable_on_refactor
  # covers: specled.expanded_behavior_tier.no_debug_info_detector_unavailable
  # covers: specled.expanded_behavior_tier.scenario.expanded_hash_stable_on_rename
  # covers: specled.expanded_behavior_tier.scenario.no_debug_info_degrades
  use ExUnit.Case, async: false
  @moduletag spec: ["specled.expanded_behavior_tier.hash_stable_on_refactor", "specled.expanded_behavior_tier.no_debug_info_detector_unavailable", "specled.expanded_behavior_tier.reads_beam_debug_info"]

  alias SpecLedEx.Realization.{ExpandedBehavior, HashStore}

  # ---------------------------------------------------------------------------
  # Fixture A: a module compiled WITH debug_info that `use`s a tiny DSL to
  # exercise the "expanded AST lives only in debug_info" path. The DSL injects
  # `handle_event/2` via `__using__/1`. Between the baseline and the rename
  # variant, only local variable names inside the injected body change — the
  # α-rename canonicalizer should hold the hash stable.
  # ---------------------------------------------------------------------------
  @dsl_baseline """
  defmodule SpecLedEx.ExpBehTest.DSL do
    defmacro __using__(_opts) do
      quote do
        def handle_event(event, state) do
          {:ok, state}
        end
      end
    end
  end

  defmodule SpecLedEx.ExpBehTest.Consumer do
    use SpecLedEx.ExpBehTest.DSL

    def plain(x), do: x + 1
  end

  defmodule SpecLedEx.ExpBehTest.Typed do
    @spec tagged(integer()) :: :ok
    def tagged(_x), do: :ok
  end
  """

  # Same DSL (identical expansion), whitespace + a local-rename in
  # source-context code in the Consumer. Canonical's α-rename collapses
  # source-context variable names and strip_meta discards line numbers, so
  # the expanded_behavior hash for the DSL-emitted handle_event/2 is
  # unaffected by edits to surrounding user code.
  @dsl_renamed """
  defmodule SpecLedEx.ExpBehTest.DSL do
    defmacro __using__(_opts) do
      quote do
        def handle_event(event, state) do
          {:ok, state}
        end
      end
    end
  end

  defmodule SpecLedEx.ExpBehTest.Consumer do
    use SpecLedEx.ExpBehTest.DSL

    # Local-rename in source-context code: x -> y. Whitespace added below.

    def plain(y),
      do: y + 1
  end

  defmodule SpecLedEx.ExpBehTest.Typed do

    @spec tagged(integer()) :: :ok
    def tagged(_x), do: :ok
  end
  """

  @dsl_body_changed """
  defmodule SpecLedEx.ExpBehTest.DSL do
    defmacro __using__(_opts) do
      quote do
        def handle_event(event, state) do
          # Real semantic change: returns :error, not :ok.
          {:error, state}
        end
      end
    end
  end

  defmodule SpecLedEx.ExpBehTest.Consumer do
    use SpecLedEx.ExpBehTest.DSL

    def plain(x), do: x + 1
  end

  defmodule SpecLedEx.ExpBehTest.Typed do
    @spec tagged(integer()) :: :ok
    def tagged(_x), do: :ok
  end
  """

  @no_debug """
  defmodule SpecLedEx.ExpBehTest.NoDebug do
    @compile {:no_debug_info, true}
    @compile {:debug_info, false}
    def silent(x), do: x
  end
  """

  @fixture_modules [
    SpecLedEx.ExpBehTest.DSL,
    SpecLedEx.ExpBehTest.Consumer,
    SpecLedEx.ExpBehTest.Typed,
    SpecLedEx.ExpBehTest.NoDebug
  ]

  defp compile_fixture!(source, tag) do
    # Purge any prior fixture modules and drop any previously-added fixture
    # code paths, otherwise ParallelCompiler resolves `use SomeDSL` against
    # the stale .beam still on the path and the new macro body never makes
    # it into the recompiled BEAM.
    for mod <- @fixture_modules do
      :code.purge(mod)
      :code.delete(mod)
    end

    for path <- Process.get(:specled_expbeh_fixture_paths, []) do
      :code.del_path(String.to_charlist(path))
    end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_expbeh_#{tag}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    source_path = Path.join(tmp_dir, "fixture_#{tag}.ex")
    File.write!(source_path, source)

    # ExUnit test runs can leave Code.compiler_options debug_info as
    # false; force it back on so our fixtures always carry debug_info
    # the ExpandedBehavior tier needs.
    previous = Code.compiler_options()[:debug_info]
    Code.put_compiler_option(:debug_info, true)

    try do
      {:ok, _mods, _diagnostics} =
        Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir,
          return_diagnostics: true
        )
    after
      Code.put_compiler_option(:debug_info, previous)
    end

    :code.add_patha(String.to_charlist(tmp_dir))
    Process.put(:specled_expbeh_fixture_paths, [
      tmp_dir | Process.get(:specled_expbeh_fixture_paths, [])
    ])

    tmp_dir
  end

  defp reload!(mods) do
    for mod <- mods do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "specled_expbeh_root_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "hash/2 — reads beam debug_info" do
    test "returns {:ok, binary} for a function that lives only in expansion" do
      dir = compile_fixture!(@dsl_baseline, "baseline_a")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      # handle_event/2 does NOT appear in the Consumer's source — it's emitted
      # by `use SpecLedEx.ExpBehTest.DSL`. ExpandedBehavior must still hash it.
      assert {:ok, hash} =
               ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")

      assert is_binary(hash)
      assert byte_size(hash) == 32

      # Same call is deterministic.
      assert {:ok, ^hash} =
               ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")
    end

    test "DSL-emitted handle_event/2 hash is stable when surrounding source is reflowed" do
      # Reflow + add whitespace + rename Consumer.plain/1's local — none of
      # which is in handle_event/2's hash input. This proves the tier hashes
      # the right MFA in isolation (its definition only) and is unaffected by
      # edits to sibling code or whitespace shifts. The harder
      # source-context α-rename guarantee is exercised by the next test on
      # `plain/1` itself, where the variable IS in the hash input.
      dir_a = compile_fixture!(@dsl_baseline, "baseline_b")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      {:ok, hash_before} =
        ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")

      dir_b = compile_fixture!(@dsl_renamed, "renamed_b")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      {:ok, hash_after_rename} =
        ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")

      assert hash_before == hash_after_rename,
             "reflow / sibling edits / whitespace must not move the hash for an unrelated MFA"

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)
    end

    test "hash is stable across local-variable rename in source-context code" do
      # `Consumer.plain/1` is source-defined (not macro-emitted), so its
      # bound variable carries `ctx in [nil, Elixir]` after expansion — the
      # exact case Canonical's α-rename DOES collapse. Renaming `x` to `y`
      # MUST not move the expanded_behavior hash for plain/1, because
      # α-rename maps both to `v1` after canonicalization.
      dir_a = compile_fixture!(@dsl_baseline, "plain_baseline")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      {:ok, plain_before} = ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.plain/1")

      dir_b = compile_fixture!(@dsl_renamed, "plain_renamed")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      {:ok, plain_after} = ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.plain/1")

      assert plain_before == plain_after,
             "α-rename must collapse `x` and `y` in source-context code so the hash is stable"

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)
    end

    test "hash flips when the DSL-emitted body changes semantically" do
      dir_a = compile_fixture!(@dsl_baseline, "baseline_c")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      {:ok, hash_before} =
        ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")

      dir_b = compile_fixture!(@dsl_body_changed, "changed_c")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      {:ok, hash_after} =
        ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")

      refute hash_before == hash_after,
             "a real semantic change in the expanded body must flip the hash"

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)
    end
  end

  describe "hash/2 — no_debug_info degrades gracefully" do
    test "returns {:error, {:debug_info_stripped, mod}} when module was compiled with @compile {:no_debug_info, true}" do
      dir = compile_fixture!(@no_debug, "no_debug_direct")

      reload!([SpecLedEx.ExpBehTest.NoDebug])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      assert {:error, {:debug_info_stripped, SpecLedEx.ExpBehTest.NoDebug}} =
               ExpandedBehavior.hash("SpecLedEx.ExpBehTest.NoDebug.silent/1")
    end

    test "does not raise on the stripped path" do
      dir = compile_fixture!(@no_debug, "no_debug_no_raise")
      reload!([SpecLedEx.ExpBehTest.NoDebug])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      # Any of several attempts against the stripped module must return a
      # tagged tuple rather than raise.
      assert match?(
               {:error, {:debug_info_stripped, _}},
               ExpandedBehavior.hash("SpecLedEx.ExpBehTest.NoDebug.silent/1")
             )
    end
  end

  describe "run/3 — detector_unavailable on stripped module" do
    test "emits a single detector_unavailable finding per stripped module, no drift finding", %{
      root: root
    } do
      dir = compile_fixture!(@no_debug, "no_debug_run")
      reload!([SpecLedEx.ExpBehTest.NoDebug])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      bindings = [
        %{
          subject_id: "S1",
          requirement_id: "S1.r1",
          mfa: "SpecLedEx.ExpBehTest.NoDebug.silent/1"
        }
      ]

      findings = ExpandedBehavior.run(bindings, nil, root: root)

      assert [finding] = findings
      assert finding["code"] == "detector_unavailable"
      assert finding["reason"] == "debug_info_stripped"
      assert finding["tier"] == "expanded_behavior"
      assert finding["module"] == "SpecLedEx.ExpBehTest.NoDebug"
      assert finding["subject_id"] == "S1"
      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    test "collapses multiple bindings targeting the same stripped module into one finding", %{
      root: root
    } do
      dir = compile_fixture!(@no_debug, "no_debug_collapse")
      reload!([SpecLedEx.ExpBehTest.NoDebug])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      bindings = [
        %{subject_id: "S1", mfa: "SpecLedEx.ExpBehTest.NoDebug.silent/1"},
        %{subject_id: "S1", mfa: "SpecLedEx.ExpBehTest.NoDebug.silent/1"}
      ]

      findings = ExpandedBehavior.run(bindings, nil, root: root)

      detector_unavailable =
        Enum.filter(findings, fn f ->
          f["code"] == "detector_unavailable" and
            f["reason"] == "debug_info_stripped"
        end)

      assert length(detector_unavailable) == 1
    end
  end

  describe "run/3 — drift findings" do
    test "emits branch_guard_realization_drift when committed hash differs", %{root: root} do
      dir = compile_fixture!(@dsl_baseline, "drift_run")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      :ok =
        HashStore.write(root, %{
          "expanded_behavior" => %{
            "SpecLedEx.ExpBehTest.Consumer.handle_event/2" => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [
        %{
          subject_id: "S1",
          requirement_id: "S1.r1",
          mfa: "SpecLedEx.ExpBehTest.Consumer.handle_event/2"
        }
      ]

      findings = ExpandedBehavior.run(bindings, nil, root: root)

      assert [drift] = Enum.filter(findings, &(&1["code"] == "branch_guard_realization_drift"))
      assert drift["tier"] == "expanded_behavior"
      assert drift["subject_id"] == "S1"
      assert drift["mfa"] == "SpecLedEx.ExpBehTest.Consumer.handle_event/2"
    end

    test "no drift finding when current hash matches committed", %{root: root} do
      dir = compile_fixture!(@dsl_baseline, "no_drift_run")

      reload!([
        SpecLedEx.ExpBehTest.DSL,
        SpecLedEx.ExpBehTest.Consumer,
        SpecLedEx.ExpBehTest.Typed
      ])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      {:ok, current} =
        ExpandedBehavior.hash("SpecLedEx.ExpBehTest.Consumer.handle_event/2")

      :ok =
        HashStore.write(root, %{
          "expanded_behavior" => %{
            "SpecLedEx.ExpBehTest.Consumer.handle_event/2" => %{
              "hash" => Base.encode16(current, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [
        %{subject_id: "S1", mfa: "SpecLedEx.ExpBehTest.Consumer.handle_event/2"}
      ]

      findings = ExpandedBehavior.run(bindings, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    test "emits branch_guard_dangling_binding when MFA does not exist", %{root: root} do
      bindings = [
        %{subject_id: "S1", mfa: "SpecLedEx.ExpBehTest.Missing.nope/0"}
      ]

      findings = ExpandedBehavior.run(bindings, nil, root: root)

      assert [d] = Enum.filter(findings, &(&1["code"] == "branch_guard_dangling_binding"))
      assert d["tier"] == "expanded_behavior"
      assert d["mfa"] == "SpecLedEx.ExpBehTest.Missing.nope/0"
    end
  end

  describe "run/3 — umbrella graceful degrade" do
    test "emits a single detector_unavailable (umbrella_unsupported) finding when umbrella?: true" do
      findings = ExpandedBehavior.run([%{subject_id: "S1", mfa: "X.y/0"}], nil, umbrella?: true)

      assert [only] = findings
      assert only["code"] == "detector_unavailable"
      assert only["reason"] == "umbrella_unsupported"
    end
  end
end
