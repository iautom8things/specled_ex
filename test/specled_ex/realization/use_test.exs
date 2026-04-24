defmodule SpecLedEx.Realization.UseTest do
  # covers: specled.use_tier.enumerate_consumers
  # covers: specled.use_tier.provider_hash_composes
  # covers: specled.use_tier.scenario.consumers_current_not_persisted
  use ExUnit.Case, async: false
  @moduletag spec: ["specled.use_tier.enumerate_consumers", "specled.use_tier.provider_hash_composes"]

  alias SpecLedEx.Realization.Use

  # ---------------------------------------------------------------------------
  # Fixtures: a real macro provider compiled to disk WITH debug_info, plus a
  # variant whose __using__/1 emits a different body so we can prove the
  # composed use-tier hash drifts on a provider expansion change.
  # ---------------------------------------------------------------------------
  @provider_baseline """
  defmodule SpecLedEx.UseTest.Provider do
    defmacro __using__(_opts) do
      quote do
        def __from_provider__, do: :v1
      end
    end
  end
  """

  @provider_changed """
  defmodule SpecLedEx.UseTest.Provider do
    defmacro __using__(_opts) do
      quote do
        def __from_provider__, do: :v2
      end
    end
  end
  """

  @no_using """
  defmodule SpecLedEx.UseTest.NoUsing do
    def hello, do: :ok
  end
  """

  defp compile_fixture!(source, tag) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_use_#{tag}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    source_path = Path.join(tmp_dir, "fixture_#{tag}.ex")
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

  describe "consumers_for/2 (specled.use_tier.enumerate_consumers)" do
    test "returns sorted unique caller modules whose callee is Provider.__using__/_" do
      provider = SpecLedEx.UseTest.ProviderA

      edges = %{
        {SpecLedEx.UseTest.C2, :__MODULE__, 0} => [{provider, :__using__, 1}],
        {SpecLedEx.UseTest.C1, :__MODULE__, 0} => [{provider, :__using__, 1}],
        {SpecLedEx.UseTest.UnrelatedCaller, :run, 0} => [{Kernel, :+, 2}],
        {SpecLedEx.UseTest.C2, :other, 0} => [{provider, :__using__, 1}]
      }

      assert Use.consumers_for(provider, tracer_edges: edges) ==
               [SpecLedEx.UseTest.C1, SpecLedEx.UseTest.C2]
    end

    test "returns [] when no caller invokes Provider.__using__" do
      provider = SpecLedEx.UseTest.NoConsumers

      edges = %{
        {Some.Mod, :run, 0} => [{Some.Other, :__using__, 1}]
      }

      assert Use.consumers_for(provider, tracer_edges: edges) == []
    end

    test "matches __using__ regardless of arity (defensive — Elixir uses arity 1)" do
      provider = SpecLedEx.UseTest.AnyArityProvider

      edges = %{
        {SpecLedEx.UseTest.CallerA, :__MODULE__, 0} => [{provider, :__using__, 0}],
        {SpecLedEx.UseTest.CallerB, :__MODULE__, 0} => [{provider, :__using__, 1}]
      }

      assert Use.consumers_for(provider, tracer_edges: edges) ==
               [SpecLedEx.UseTest.CallerA, SpecLedEx.UseTest.CallerB]
    end

    test "excludes the provider itself even if it self-references __using__" do
      provider = SpecLedEx.UseTest.SelfRef

      edges = %{
        {provider, :setup, 0} => [{provider, :__using__, 1}],
        {SpecLedEx.UseTest.RealConsumer, :__MODULE__, 0} => [{provider, :__using__, 1}]
      }

      assert Use.consumers_for(provider, tracer_edges: edges) ==
               [SpecLedEx.UseTest.RealConsumer]
    end
  end

  describe "consumers_for/2 — current set, not persisted (specled.use_tier.scenario.consumers_current_not_persisted)" do
    test "returns the current edge set; any pre-existing state.json record is ignored" do
      provider = SpecLedEx.UseTest.NotPersisted

      # Simulate the tracer manifest reflecting a NEW consumer C3. Even if a
      # state.json had only [C1, C2] persisted, consumers_for reads the tracer
      # (current), never the store.
      edges = %{
        {SpecLedEx.UseTest.C1, :__MODULE__, 0} => [{provider, :__using__, 1}],
        {SpecLedEx.UseTest.C2, :__MODULE__, 0} => [{provider, :__using__, 1}],
        {SpecLedEx.UseTest.C3, :__MODULE__, 0} => [{provider, :__using__, 1}]
      }

      assert Use.consumers_for(provider, tracer_edges: edges) ==
               [SpecLedEx.UseTest.C1, SpecLedEx.UseTest.C2, SpecLedEx.UseTest.C3]
    end
  end

  describe "hash/2 — provider hash composition (specled.use_tier.provider_hash_composes)" do
    test "returns {:ok, hash} composing provider expanded_behavior + sorted consumers" do
      dir = compile_fixture!(@provider_baseline, "baseline_ok")
      reload!([SpecLedEx.UseTest.Provider])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      assert {:ok, hash} =
               Use.hash("SpecLedEx.UseTest.Provider", tracer_edges: %{})

      assert is_binary(hash)
      assert byte_size(hash) == 32
    end

    test "hash flips when consumer set changes (provider expansion same)" do
      dir = compile_fixture!(@provider_baseline, "consumer_set_a")
      reload!([SpecLedEx.UseTest.Provider])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      provider_str = "SpecLedEx.UseTest.Provider"

      {:ok, hash_a} =
        Use.hash(provider_str,
          tracer_edges: %{
            {SpecLedEx.UseTest.X1, :__MODULE__, 0} =>
              [{SpecLedEx.UseTest.Provider, :__using__, 1}]
          }
        )

      {:ok, hash_b} =
        Use.hash(provider_str,
          tracer_edges: %{
            {SpecLedEx.UseTest.X1, :__MODULE__, 0} =>
              [{SpecLedEx.UseTest.Provider, :__using__, 1}],
            {SpecLedEx.UseTest.X2, :__MODULE__, 0} =>
              [{SpecLedEx.UseTest.Provider, :__using__, 1}]
          }
        )

      refute hash_a == hash_b,
             "adding a consumer must change the use-tier composed hash"
    end

    test "hash flips when provider expansion changes (consumer set same)" do
      dir_a = compile_fixture!(@provider_baseline, "expansion_a")
      reload!([SpecLedEx.UseTest.Provider])

      provider_str = "SpecLedEx.UseTest.Provider"
      edges = %{{Foo.Bar, :m, 0} => [{SpecLedEx.UseTest.Provider, :__using__, 1}]}

      {:ok, hash_v1} = Use.hash(provider_str, tracer_edges: edges)

      dir_b = compile_fixture!(@provider_changed, "expansion_b")
      reload!([SpecLedEx.UseTest.Provider])

      {:ok, hash_v2} = Use.hash(provider_str, tracer_edges: edges)

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir_a))
        :code.del_path(String.to_charlist(dir_b))
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      refute hash_v1 == hash_v2,
             "changing the provider's __using__ body must move the use-tier hash"
    end

    test "hash is stable for the same (provider expansion, consumer set)" do
      dir = compile_fixture!(@provider_baseline, "stable")
      reload!([SpecLedEx.UseTest.Provider])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      provider_str = "SpecLedEx.UseTest.Provider"
      edges = %{{Foo.Bar, :m, 0} => [{SpecLedEx.UseTest.Provider, :__using__, 1}]}

      {:ok, h1} = Use.hash(provider_str, tracer_edges: edges)
      {:ok, h2} = Use.hash(provider_str, tracer_edges: edges)

      assert h1 == h2
    end

    test "returns {:error, {:not_found, _}} when provider has no __using__" do
      dir = compile_fixture!(@no_using, "no_using")
      reload!([SpecLedEx.UseTest.NoUsing])

      on_exit(fn ->
        :code.del_path(String.to_charlist(dir))
        File.rm_rf!(dir)
      end)

      assert {:error, {:not_found, _}} =
               Use.hash("SpecLedEx.UseTest.NoUsing", tracer_edges: %{})
    end
  end
end
