defmodule SpecLedEx.Compiler.TracerTest do
  # Tracer writes to named ETS tables shared by the VM.
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag spec: [
               "specled.compiler_tracer.captures_remote_calls",
               "specled.compiler_tracer.etf_read_direct",
               "specled.compiler_tracer.registered_in_mix_exs"
             ]

  alias SpecLedEx.Compiler.Tracer

  @manifest_path Path.join(["_build", Atom.to_string(Mix.env()), ".spec", "xref_mfa.etf"])

  # Flush tests write to the real per-env manifest; snapshot and restore it so
  # test-fixture edges never leak into the file other tooling reads.
  setup do
    Tracer.reset()

    snapshot = if File.exists?(@manifest_path), do: File.read!(@manifest_path)

    on_exit(fn ->
      Tracer.reset()

      case snapshot do
        nil ->
          File.rm(@manifest_path)

        binary ->
          File.mkdir_p!(Path.dirname(@manifest_path))
          File.write!(@manifest_path, binary)
      end
    end)

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
    test "remote call in a compiled module produces an edge in the ETF (in-process)" do
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

    @tag :integration
    test "fixture subprocess compile with tracer registered produces fixture ETF" do
      fixture_root = Path.expand(Path.join(["test", "fixtures", "sample_project"]))
      fixture_build = Path.join(fixture_root, "_build")
      fixture_etf = Path.join([fixture_build, "test", ".spec", "xref_mfa.etf"])

      File.rm_rf!(fixture_build)

      parent_lib = Path.expand("_build/#{Mix.env()}/lib")

      {output, status} =
        System.cmd("mix", ["compile"],
          cd: fixture_root,
          env: [
            {"MIX_ENV", "test"},
            {"ERL_LIBS", parent_lib}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, "fixture compile failed: #{output}"

      assert File.exists?(fixture_etf),
             "expected fixture ETF at #{fixture_etf}; compile output:\n#{output}"

      edges = fixture_etf |> File.read!() |> :erlang.binary_to_term()

      assert is_map(edges), "ETF should deserialize to a map, got: #{inspect(edges)}"
      assert map_size(edges) > 0, "expected at least one caller entry, got empty map"

      sample_keys =
        edges
        |> Map.keys()
        |> Enum.filter(fn {mod, _fun, _arity} -> mod == Sample end)

      assert sample_keys != [],
             "expected at least one edge from Sample.*/*, got keys: #{inspect(Map.keys(edges))}"
    end
  end

  describe "Tracer.merge_edges/3 (specled.compiler_tracer.merge_on_flush)" do
    @tag spec: "specled.compiler_tracer.merge_on_flush"
    test "non-session entries are preserved; session-caller entries are replaced" do
      previous = %{
        {ModKeep, :f, 1} => [{Enum, :map, 2}],
        {ModRecompiled, :g, 0} => [{String, :old_callee, 1}]
      }

      session_edges = %{{ModRecompiled, :g, 0} => [{String, :upcase, 1}]}

      merged = Tracer.merge_edges(previous, MapSet.new([ModRecompiled]), session_edges)

      assert merged[{ModKeep, :f, 1}] == [{Enum, :map, 2}]
      assert merged[{ModRecompiled, :g, 0}] == [{String, :upcase, 1}]
    end

    @tag spec: "specled.compiler_tracer.session_module_replacement"
    test "session module with zero session edges drops all its stale entries" do
      previous = %{
        {ModRecompiled, :g, 0} => [{String, :old_callee, 1}],
        {ModRecompiled, :h, 2} => [{Enum, :sort, 1}],
        {ModKeep, :f, 1} => [{Enum, :map, 2}]
      }

      merged = Tracer.merge_edges(previous, MapSet.new([ModRecompiled]), %{})

      refute Map.has_key?(merged, {ModRecompiled, :g, 0})
      refute Map.has_key?(merged, {ModRecompiled, :h, 2})
      assert Map.has_key?(merged, {ModKeep, :f, 1})
    end

    @tag spec: "specled.compiler_tracer.merge_on_flush"
    test "callee lists come out sorted and deduplicated" do
      previous = %{{ModKeep, :f, 1} => [{Zeta, :z, 0}, {Alpha, :a, 0}, {Zeta, :z, 0}]}
      session_edges = %{{ModNew, :n, 0} => [{Beta, :b, 1}, {Beta, :b, 1}, {Alpha, :a, 0}]}

      merged = Tracer.merge_edges(previous, MapSet.new(), session_edges)

      assert merged[{ModKeep, :f, 1}] == [{Alpha, :a, 0}, {Zeta, :z, 0}]
      assert merged[{ModNew, :n, 0}] == [{Alpha, :a, 0}, {Beta, :b, 1}]
    end

    @tag spec: "specled.compiler_tracer.merge_on_flush"
    property "merge keeps exactly non-session previous entries plus session edges, and is idempotent" do
      module_pool = [ModA, ModB, ModC, ModD]

      mfa_gen =
        gen all(
              mod <- member_of(module_pool),
              fun <- member_of([:f, :g, :h]),
              arity <- integer(0..2)
            ) do
          {mod, fun, arity}
        end

      edges_gen = map_of(mfa_gen, list_of(mfa_gen, max_length: 4), max_length: 8)

      check all(
              previous <- edges_gen,
              session_edges <- edges_gen,
              session_modules <- uniq_list_of(member_of(module_pool), max_length: 3)
            ) do
        session_set = MapSet.new(session_modules)
        merged = Tracer.merge_edges(previous, session_set, session_edges)

        canonical = fn callees -> callees |> Enum.sort() |> Enum.dedup() end

        expected_kept =
          for {{mod, _f, _a} = caller, callees} <- previous,
              not MapSet.member?(session_set, mod),
              into: %{},
              do: {caller, callees}

        expected =
          expected_kept
          |> Map.merge(session_edges)
          |> Map.new(fn {caller, callees} -> {caller, canonical.(callees)} end)

        assert merged == expected

        # Idempotence: re-merging the result with the same inputs is stable.
        assert Tracer.merge_edges(merged, session_set, session_edges) == merged
      end
    end
  end

  describe "Tracer.prune_edges/2 (specled.compiler_tracer.merge_on_flush)" do
    @tag spec: "specled.compiler_tracer.seed_time_ghost_prune"
    test "nil and empty live sets are identity (prune disabled)" do
      edges = %{{GhostMod, :f, 0} => [{Enum, :map, 2}]}

      assert Tracer.prune_edges(edges, nil) == edges
      assert Tracer.prune_edges(edges, MapSet.new()) == edges
    end

    @tag spec: "specled.compiler_tracer.seed_time_ghost_prune"
    test "callers absent from a non-empty live set are dropped" do
      edges = %{
        {LiveMod, :f, 0} => [{Enum, :map, 2}],
        {GhostMod, :g, 1} => [{Enum, :sort, 1}]
      }

      pruned = Tracer.prune_edges(edges, MapSet.new([LiveMod]))

      assert Map.keys(pruned) == [{LiveMod, :f, 0}]
    end
  end

  describe "merge-on-flush through trace/2 (specled.compiler_tracer.scenario.recompiled_module_replaces_edges)" do
    @tag spec: "specled.compiler_tracer.session_module_replacement"
    test "recompiled module with zero captured edges drops its stale entries; others preserved" do
      # Both caller modules are real host-project modules, so the seed-time
      # prune (which runs against spec_led_ex's own compile manifest in this
      # VM) keeps them.
      stale = %{
        {SpecLedEx.Overlap, :analyze, 2} => [{Enum, :stale_marker, 1}],
        {SpecLedEx.Parser, :parse, 1} => [{String, :split, 2}]
      }

      File.mkdir_p!(Path.dirname(@manifest_path))
      File.write!(@manifest_path, :erlang.term_to_binary(stale))
      Tracer.reset()

      env = %Macro.Env{module: SpecLedEx.Overlap, function: nil}
      Tracer.trace(:start, env)
      Tracer.trace(:on_module, env)

      edges = @manifest_path |> File.read!() |> :erlang.binary_to_term()

      refute Map.has_key?(edges, {SpecLedEx.Overlap, :analyze, 2})
      assert edges[{SpecLedEx.Parser, :parse, 1}] == [{String, :split, 2}]
    end

    @tag spec: "specled.compiler_tracer.seed_time_ghost_prune"
    test "ghost callers absent from the compile manifest are pruned at merge-base seed time" do
      ghost = Module.concat([SpecLedEx, "GhostModuleNeverCompiled"])

      stale = %{
        {ghost, :f, 0} => [{Enum, :map, 2}],
        {SpecLedEx.Parser, :parse, 1} => [{String, :split, 2}]
      }

      File.mkdir_p!(Path.dirname(@manifest_path))
      File.write!(@manifest_path, :erlang.term_to_binary(stale))
      Tracer.reset()

      env = %Macro.Env{module: FlushGhostTrigger, function: nil}
      Tracer.trace(:start, env)
      Tracer.trace(:on_module, env)

      edges = @manifest_path |> File.read!() |> :erlang.binary_to_term()

      refute Map.has_key?(edges, {ghost, :f, 0})
      assert Map.has_key?(edges, {SpecLedEx.Parser, :parse, 1})
    end

    @tag spec: "specled.compiler_tracer.merge_on_flush"
    test "flush leaves no temp-file litter next to the manifest" do
      env = %Macro.Env{module: AtomicFlushCaller, function: {:f, 0}}
      Tracer.trace(:start, env)
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env)
      Tracer.trace(:on_module, env)

      litter =
        @manifest_path
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, ".tmp."))

      assert litter == []
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
