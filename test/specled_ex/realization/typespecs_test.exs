defmodule SpecLedEx.Realization.TypespecsTest do
  # covers: specled.expanded_behavior_tier.typespecs_hashes_spec_and_type
  # covers: specled.expanded_behavior_tier.typespecs_drift_finding
  # covers: specled.expanded_behavior_tier.scenario.typespec_arg_change_drifts
  use ExUnit.Case, async: false

  alias SpecLedEx.Realization.{HashStore, Typespecs}

  @baseline """
  defmodule SpecLedEx.TypespecsTest.M do
    @type id :: integer()

    @spec foo(integer()) :: :ok
    def foo(_), do: :ok

    @spec bar(id()) :: :ok
    def bar(_), do: :ok
  end
  """

  # Same spec, formatted differently (extra whitespace, blank lines).
  @baseline_reformatted """
  defmodule SpecLedEx.TypespecsTest.M do

    @type id :: integer()


    @spec foo(integer()) :: :ok
    def foo(_),
      do: :ok

    @spec bar(id()) :: :ok
    def bar(_),
      do: :ok
  end
  """

  # foo's arg type changed integer() -> binary()
  @arg_changed """
  defmodule SpecLedEx.TypespecsTest.M do
    @type id :: integer()

    @spec foo(binary()) :: :ok
    def foo(_), do: :ok

    @spec bar(id()) :: :ok
    def bar(_), do: :ok
  end
  """

  # Declaration order swapped: bar declared before foo.
  @reordered """
  defmodule SpecLedEx.TypespecsTest.M do
    @type id :: integer()

    @spec bar(id()) :: :ok
    def bar(_), do: :ok

    @spec foo(integer()) :: :ok
    def foo(_), do: :ok
  end
  """

  @no_debug """
  defmodule SpecLedEx.TypespecsTest.NoDebug do
    @compile {:no_debug_info, true}
    @compile {:debug_info, false}
    @spec hidden() :: :ok
    def hidden, do: :ok
  end
  """

  defp compile_fixture!(source, tag) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_typespecs_#{tag}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    source_path = Path.join(tmp_dir, "ts_#{tag}.ex")
    File.write!(source_path, source)

    previous = Code.compiler_options()[:debug_info]
    Code.put_compiler_option(:debug_info, true)

    try do
      {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir)
    after
      Code.put_compiler_option(:debug_info, previous)
    end

    :code.add_patha(String.to_charlist(tmp_dir))
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
        "specled_typespecs_root_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "hash/2 — baseline and stability" do
    test "returns {:ok, binary} for a module with @spec and @type declarations" do
      dir = compile_fixture!(@baseline, "baseline_ok")
      reload!([SpecLedEx.TypespecsTest.M])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      assert {:ok, hash} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")
      assert is_binary(hash)
      assert byte_size(hash) == 32
    end

    test "is stable under whitespace-only reformatting of @spec declarations" do
      dir_a = compile_fixture!(@baseline, "ws_baseline")
      reload!([SpecLedEx.TypespecsTest.M])
      {:ok, hash_before} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")

      dir_b = compile_fixture!(@baseline_reformatted, "ws_reformat")
      reload!([SpecLedEx.TypespecsTest.M])
      {:ok, hash_after} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      assert hash_before == hash_after,
             "whitespace reformatting of @spec must not move the typespecs hash"
    end

    test "sorts declarations so source-order swaps do not drift the hash" do
      dir_a = compile_fixture!(@baseline, "order_baseline")
      reload!([SpecLedEx.TypespecsTest.M])

      {:ok, foo_baseline} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")
      {:ok, bar_baseline} = Typespecs.hash("SpecLedEx.TypespecsTest.M.bar/1")

      dir_b = compile_fixture!(@reordered, "reordered")
      reload!([SpecLedEx.TypespecsTest.M])

      {:ok, foo_reordered} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")
      {:ok, bar_reordered} = Typespecs.hash("SpecLedEx.TypespecsTest.M.bar/1")

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      assert foo_baseline == foo_reordered
      assert bar_baseline == bar_reordered
    end
  end

  describe "hash/2 — drift on arg type change" do
    test "flips when an @spec's argument type changes" do
      dir_a = compile_fixture!(@baseline, "arg_baseline")
      reload!([SpecLedEx.TypespecsTest.M])
      {:ok, before} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")

      dir_b = compile_fixture!(@arg_changed, "arg_changed")
      reload!([SpecLedEx.TypespecsTest.M])
      {:ok, after_hash} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      refute before == after_hash,
             "a change to foo/1's @spec arg type (integer() -> binary()) must flip the typespecs hash"
    end
  end

  describe "hash/2 — no_debug_info" do
    test "returns {:error, {:debug_info_stripped, mod}} when module has no debug_info" do
      dir = compile_fixture!(@no_debug, "no_debug_ts")
      reload!([SpecLedEx.TypespecsTest.NoDebug])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      assert {:error, {:debug_info_stripped, SpecLedEx.TypespecsTest.NoDebug}} =
               Typespecs.hash("SpecLedEx.TypespecsTest.NoDebug.hidden/0")
    end
  end

  describe "run/3 — drift findings" do
    test "emits branch_guard_realization_drift with tier `:typespecs` on arg type change", %{
      root: root
    } do
      # Commit the baseline hash.
      dir_a = compile_fixture!(@baseline, "run_drift_baseline")
      reload!([SpecLedEx.TypespecsTest.M])
      {:ok, baseline_hash} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")

      :ok =
        HashStore.write(root, %{
          "typespecs" => %{
            "SpecLedEx.TypespecsTest.M.foo/1" => %{
              "hash" => Base.encode16(baseline_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      # Switch to the arg-changed module and run.
      dir_b = compile_fixture!(@arg_changed, "run_drift_changed")
      reload!([SpecLedEx.TypespecsTest.M])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      bindings = [
        %{
          subject_id: "S1",
          requirement_id: "S1.r1",
          mfa: "SpecLedEx.TypespecsTest.M.foo/1"
        }
      ]

      findings = Typespecs.run(bindings, nil, root: root)

      assert [drift] = Enum.filter(findings, &(&1["code"] == "branch_guard_realization_drift"))
      assert drift["tier"] == "typespecs"
      assert drift["mfa"] == "SpecLedEx.TypespecsTest.M.foo/1"
      assert drift["subject_id"] == "S1"
    end

    test "no drift finding when hash matches committed", %{root: root} do
      dir = compile_fixture!(@baseline, "run_no_drift")
      reload!([SpecLedEx.TypespecsTest.M])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      {:ok, current} = Typespecs.hash("SpecLedEx.TypespecsTest.M.foo/1")

      :ok =
        HashStore.write(root, %{
          "typespecs" => %{
            "SpecLedEx.TypespecsTest.M.foo/1" => %{
              "hash" => Base.encode16(current, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [
        %{subject_id: "S1", mfa: "SpecLedEx.TypespecsTest.M.foo/1"}
      ]

      findings = Typespecs.run(bindings, nil, root: root)
      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    test "emits detector_unavailable for stripped module, never raises", %{root: root} do
      dir = compile_fixture!(@no_debug, "run_stripped_ts")
      reload!([SpecLedEx.TypespecsTest.NoDebug])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      bindings = [
        %{subject_id: "S1", mfa: "SpecLedEx.TypespecsTest.NoDebug.hidden/0"}
      ]

      findings = Typespecs.run(bindings, nil, root: root)

      assert [only] = findings
      assert only["code"] == "detector_unavailable"
      assert only["reason"] == "debug_info_stripped"
      assert only["tier"] == "typespecs"
    end
  end
end
