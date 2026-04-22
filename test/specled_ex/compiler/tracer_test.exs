defmodule SpecLedEx.Compiler.TracerTest do
  use ExUnit.Case, async: false

  alias SpecLedEx.Compiler.Tracer

  @manifest_path Path.join(["_build", Atom.to_string(Mix.env()), ".spec", "xref_mfa.etf"])

  setup do
    table = Tracer.table_name()

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  describe "mix.exs registration (specled.compiler_tracer.registered_in_mix_exs)" do
    test "project mix.exs registers the tracer via elixirc_options" do
      assert File.read!("mix.exs") =~ "tracers: [SpecLedEx.Compiler.Tracer]"
    end

    test "sample_project fixture mix.exs registers the tracer via elixirc_options" do
      path = Path.join(["test", "fixtures", "sample_project", "mix.exs"])
      assert File.read!(path) =~ "tracers: [SpecLedEx.Compiler.Tracer]"
    end
  end

  describe "trace/2 events (specled.compiler_tracer.captures_remote_calls)" do
    test "remote_function events accumulate as {caller_mfa, callee_mfa}" do
      env = %Macro.Env{module: FakeCaller, function: {:do_thing, 1}}

      Tracer.trace(:start, env)
      assert :ok = Tracer.trace({:remote_function, [line: 1], Kernel, :+, 2}, env)

      entries = :ets.tab2list(Tracer.table_name())
      assert {{FakeCaller, :do_thing, 1}, {Kernel, :+, 2}} in entries
    end

    test "imported_function and imported_macro events also accumulate" do
      env = %Macro.Env{module: FakeCaller2, function: {:run, 0}}
      Tracer.trace(:start, env)
      Tracer.trace({:imported_function, [], Enum, :map, 2}, env)
      Tracer.trace({:imported_macro, [], Kernel, :if, 2}, env)

      entries = :ets.tab2list(Tracer.table_name())
      assert {{FakeCaller2, :run, 0}, {Enum, :map, 2}} in entries
      assert {{FakeCaller2, :run, 0}, {Kernel, :if, 2}} in entries
    end

    test "events with nil env.module are ignored" do
      env = %Macro.Env{module: nil, function: nil}
      Tracer.trace(:start, env)
      Tracer.trace({:remote_function, [], Kernel, :+, 2}, env)
      assert :ets.tab2list(Tracer.table_name()) == []
    end

    test "unhandled events are no-ops" do
      env = %Macro.Env{module: nil, function: nil}
      assert :ok = Tracer.trace(:stop, env)
      assert :ok = Tracer.trace({:alias, [], Foo, Bar, []}, env)
    end
  end

  describe "on :on_module flush (specled.compiler_tracer.captures_remote_calls, etf_read_direct)" do
    test "writes ETF manifest readable directly via :erlang.binary_to_term/1" do
      env = %Macro.Env{module: FlushCaller, function: {:f, 0}}
      Tracer.trace(:start, env)
      Tracer.trace({:remote_function, [], Other, :callee, 1}, env)
      Tracer.trace(:on_module, env)

      assert File.exists?(@manifest_path), "manifest not written at #{@manifest_path}"

      edges = @manifest_path |> File.read!() |> :erlang.binary_to_term()
      assert is_map(edges)
      assert {Other, :callee, 1} in Map.fetch!(edges, {FlushCaller, :f, 0})
    end

    test "accepts the tuple form {:on_module, bytecode, _ignore}" do
      env = %Macro.Env{module: FlushCaller2, function: {:g, 0}}
      Tracer.trace(:start, env)
      Tracer.trace({:remote_function, [], Module2, :call, 0}, env)
      Tracer.trace({:on_module, <<>>, []}, env)

      assert File.exists?(@manifest_path)
      edges = @manifest_path |> File.read!() |> :erlang.binary_to_term()
      assert {Module2, :call, 0} in Map.fetch!(edges, {FlushCaller2, :g, 0})
    end

    test "duplicate edges collapse; callees list stays a set" do
      env = %Macro.Env{module: DupCaller, function: {:h, 0}}
      Tracer.trace(:start, env)
      Tracer.trace({:remote_function, [], Kernel, :+, 2}, env)
      Tracer.trace({:remote_function, [], Kernel, :+, 2}, env)
      Tracer.trace(:on_module, env)

      edges = @manifest_path |> File.read!() |> :erlang.binary_to_term()
      callees = Map.fetch!(edges, {DupCaller, :h, 0})
      assert Enum.count(callees, &(&1 == {Kernel, :+, 2})) == 1
    end
  end

  describe "scenario specled.compiler_tracer.scenario.mfa_edges_emitted" do
    test "remote call in a compiled module produces an edge in the ETF" do
      unique = System.unique_integer([:positive])
      caller_mod = Module.concat([SpecLedEx, "TracerScenarioFixture#{unique}"])
      callee_mod = Module.concat([SpecLedEx, "TracerScenarioCallee#{unique}"])

      Code.compile_string("""
      defmodule #{inspect(callee_mod)} do
        def callee(_x), do: :ok
      end
      """)

      prev = Code.get_compiler_option(:tracers) || []

      try do
        Code.put_compiler_option(:tracers, [Tracer])

        Code.compile_string("""
        defmodule #{inspect(caller_mod)} do
          def caller, do: #{inspect(callee_mod)}.callee(1)
        end
        """)
      after
        Code.put_compiler_option(:tracers, prev)
      end

      assert File.exists?(@manifest_path)
      edges = @manifest_path |> File.read!() |> :erlang.binary_to_term()

      caller_key = {caller_mod, :caller, 0}
      assert Map.has_key?(edges, caller_key), "no edge recorded for #{inspect(caller_key)}"
      assert {callee_mod, :callee, 1} in Map.fetch!(edges, caller_key)
    end
  end

  describe "manifest_path/1" do
    test "resolves to _build/<env>/.spec/xref_mfa.etf" do
      assert Tracer.manifest_path(:test) ==
               Path.join(["_build", "test", ".spec", "xref_mfa.etf"])

      assert Tracer.manifest_path(:dev) ==
               Path.join(["_build", "dev", ".spec", "xref_mfa.etf"])
    end

    test "defaults to current Mix.env/0" do
      assert Tracer.manifest_path() == Tracer.manifest_path(Mix.env())
    end
  end
end
