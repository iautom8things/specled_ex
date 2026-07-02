defmodule SpecLedEx.Compiler.Tracer do
  # covers: specled.compiler_tracer.single_file_cap
  @moduledoc """
  `Code.Tracer` that captures MFA-level callee edges during compile.

  Registered in `mix.exs` via `elixirc_options: [tracers: [#{inspect(__MODULE__)}]]`,
  this tracer receives `:remote_function`, `:imported_function`, and
  `:imported_macro` events during compilation, accumulating edges
  `{caller_module, caller_fun, caller_arity} => [{callee_module, callee_fun, callee_arity}]`.

  On each `:on_module` event, the manifest at `_build/\#{Mix.env()}/.spec/xref_mfa.etf`
  is rewritten as a **merge**, never a whole-file replacement — an incremental
  compile only traces the modules it recompiles, so replacing the file would
  truncate the callee graph to the recompiled subset. Semantics (see
  `specled.compiler_tracer.merge_on_flush` and
  `specled.decision.tracer_manifest_merge_on_flush`):

    * Modules compiled this session are tracked from `:on_module` events in a
      second named ETS table — never inferred from edge callers, so a
      recompiled module with zero remote calls still drops its stale entries.
    * The merge base is the pre-session manifest file, read once per session
      and cached as a single `{:merge_base, map}` row, pruned at seed time of
      callers absent from the project's compile manifest (non-empty manifests
      only; the prune lags one compile for deletions — read-time filtering in
      the implementation tier is the authoritative ghost prune).
    * Callee lists are written sorted and deduplicated; writes go through a
      unique temp file + `File.rename!/2`, so readers never see a torn file.

  Accepted races, unchanged from the pre-merge design: a slow earlier flush's
  write can land after a later flush's (any such write is an internally
  consistent subset union, corrected by the next compile), and edges from
  earlier same-VM compiles of since-changed code persist for the VM's
  lifetime (production compile pipelines are fresh-VM per session).

  ## Self-containment (do not factor trace-time code out)

  Everything reachable from `trace/2` must live in this module and call only
  `Mix`/stdlib modules: the tracer can be reached over a pruned code path —
  e.g. a fixture project loading it via `ERL_LIBS` — where a lazily-loaded
  sibling `SpecLedEx.*` module is unavailable mid-compile. `Mix` itself is
  resident in every compiling VM and safe to call.

  See `specled.decision.custom_compile_tracer` for the rationale behind this
  approach versus post-hoc `mix xref graph --format json` (which does not exist).

  ## Note on the tracer contract

  Elixir's tracer API is structural, not a formal `@behaviour`: any module that
  exports `trace/2` can be registered in `elixirc_options[:tracers]`. We therefore
  document the contract here rather than annotate with `@impl`.
  """

  @table :specled_compiler_tracer_edges
  @meta_table :specled_compiler_tracer_meta

  @manifest_subpath Path.join(".spec", "xref_mfa.etf")

  @doc false
  @spec table_name() :: atom()
  def table_name, do: @table

  @doc false
  @spec meta_table_name() :: atom()
  def meta_table_name, do: @meta_table

  @doc false
  @spec ensure_table() :: atom()
  def ensure_table do
    ensure_named_table(@table, :bag)
  end

  @doc false
  @spec ensure_meta_table() :: atom()
  def ensure_meta_table do
    ensure_named_table(@meta_table, :set)
  end

  defp ensure_named_table(name, type) do
    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, [
            :public,
            :named_table,
            type,
            {:heir, heir_pid(), :specled_tracer_heir},
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end

    name
  end

  # Parallel compiler workers create and use the tables, but each worker is
  # short-lived — on death a table would be destroyed unless ownership
  # transfers. `:application_controller` is started by the kernel app and lives
  # for the entire VM, so it's a safe heir: the tables persist across worker
  # lifecycles for the full compile. Falls back to `self/0` if the controller
  # is somehow unavailable (unusual — only during very early VM boot).
  defp heir_pid do
    case :erlang.whereis(:application_controller) do
      pid when is_pid(pid) -> pid
      _ -> self()
    end
  end

  # Clears both the edge table and the session/meta table (session-compiled
  # markers and the cached merge base). Test isolation only — a compile
  # session never resets itself.
  @doc false
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(ensure_table())
    :ets.delete_all_objects(ensure_meta_table())
    :ok
  end

  @doc """
  Returns the manifest path for the given `env` relative to the current project
  build path.
  """
  @spec manifest_path(atom()) :: Path.t()
  def manifest_path(env \\ nil) do
    env = env || Mix.env()
    Path.join(["_build", Atom.to_string(env), @manifest_subpath])
  end

  @doc """
  Tracer entry point. Receives compile events from the Elixir parallel compiler
  and accumulates `{caller_mfa, callee_mfa}` edges for remote/imported call
  events; merges the accumulated edges into the ETF manifest on `:on_module`.
  """
  @spec trace(atom() | tuple(), Macro.Env.t()) :: :ok
  def trace(:start, _env) do
    ensure_table()
    ensure_meta_table()
    :ok
  end

  def trace({:remote_function, _meta, module, name, arity}, env),
    do: capture(env, module, name, arity)

  def trace({:remote_macro, _meta, module, name, arity}, env),
    do: capture(env, module, name, arity)

  def trace({:imported_function, _meta, module, name, arity}, env),
    do: capture(env, module, name, arity)

  def trace({:imported_macro, _meta, module, name, arity}, env),
    do: capture(env, module, name, arity)

  def trace(:on_module, env), do: flush(env)
  def trace({:on_module, _bytecode, _ignore}, env), do: flush(env)

  def trace(_event, _env), do: :ok

  defp capture(%Macro.Env{module: nil}, _m, _n, _a), do: :ok

  defp capture(%Macro.Env{module: caller_module} = env, callee_module, callee_name, callee_arity)
       when is_atom(caller_module) and is_atom(callee_module) and is_atom(callee_name) and
              is_integer(callee_arity) do
    caller_mfa = {caller_module, caller_fun(env), caller_arity(env)}
    callee_mfa = {callee_module, callee_name, callee_arity}
    :ets.insert(ensure_table(), {caller_mfa, callee_mfa})
    :ok
  end

  defp capture(_env, _m, _n, _a), do: :ok

  defp caller_fun(%Macro.Env{function: {fun, _arity}}) when is_atom(fun), do: fun
  defp caller_fun(_), do: nil

  defp caller_arity(%Macro.Env{function: {_fun, arity}}) when is_integer(arity), do: arity
  defp caller_arity(_), do: nil

  defp flush(env) do
    ensure_table()
    ensure_meta_table()
    record_session_module(env)

    path = manifest_path()
    File.mkdir_p!(Path.dirname(path))

    edges = merge_edges(fetch_merge_base(path), session_modules(), session_edges())

    write_atomic(path, :erlang.term_to_binary(edges))
    :ok
  end

  # The session marker must land before the merge is computed so a recompiled
  # module with zero remote calls still drops its stale merge-base entries.
  defp record_session_module(%Macro.Env{module: module}) when is_atom(module) and module != nil do
    :ets.insert(@meta_table, {{:session_module, module}, true})
    :ok
  end

  defp record_session_module(_env), do: :ok

  defp session_modules do
    @meta_table
    |> :ets.match({{:session_module, :"$1"}, :_})
    |> MapSet.new(fn [module] -> module end)
  end

  defp session_edges do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {caller, callee}, acc ->
      Map.update(acc, caller, [callee], &[callee | &1])
    end)
  end

  # Seed-or-fetch the pre-session merge base. `:ets.insert_new/2` arbitrates
  # concurrent first flushes; a loser re-reads the winner's row. Both racers
  # read identical file content — writes only happen after seeding — so
  # either map is correct even in the (harmless) double-read window.
  defp fetch_merge_base(path) do
    case :ets.lookup(@meta_table, :merge_base) do
      [{:merge_base, base}] ->
        base

      [] ->
        base = path |> read_manifest_file() |> prune_edges(live_modules())

        if :ets.insert_new(@meta_table, {:merge_base, base}) do
          base
        else
          case :ets.lookup(@meta_table, :merge_base) do
            [{:merge_base, winner}] -> winner
            [] -> base
          end
        end
    end
  end

  defp read_manifest_file(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          case :erlang.binary_to_term(binary) do
            map when is_map(map) -> map
            _ -> %{}
          end
        rescue
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # Live-module set for seed-time pruning, from the current project's compile
  # manifest, read via `Mix.Compilers.Elixir.read_manifest/1` directly (NOT
  # `SpecLedEx.Compiler.Manifest` — see the self-containment moduledoc note).
  # Returns nil (prune disabled) when the manifest is missing, unreadable, or
  # empty — a cold build must not wipe the merge base.
  defp live_modules do
    path = Path.join(Mix.Project.manifest_path(), "compile.elixir")

    modules =
      if File.exists?(path) do
        case Mix.Compilers.Elixir.read_manifest(path) do
          {modules_map, _sources_map} when is_map(modules_map) -> Map.keys(modules_map)
          modules_map when is_map(modules_map) -> Map.keys(modules_map)
          _ -> []
        end
      else
        []
      end

    case modules do
      [] -> nil
      modules -> MapSet.new(modules)
    end
  rescue
    _ -> nil
  end

  # Merges `session_edges` over `previous`, dropping every `previous` entry
  # whose caller module was compiled this session — a session module owns its
  # entries outright. Callee lists in the result are sorted and deduplicated
  # so identical trees produce identical manifests. Public for direct unit
  # testing; not part of the tracer contract.
  @doc false
  @spec merge_edges(map(), MapSet.t(), map()) :: map()
  def merge_edges(previous, %MapSet{} = session_modules, session_edges)
      when is_map(previous) and is_map(session_edges) do
    previous
    |> Enum.reject(fn {caller, _callees} -> session_caller?(caller, session_modules) end)
    |> Map.new()
    |> Map.merge(session_edges)
    |> Map.new(fn {caller, callees} -> {caller, canonical_callees(callees)} end)
  end

  defp session_caller?({module, _fun, _arity}, session_modules),
    do: MapSet.member?(session_modules, module)

  defp session_caller?(_other, _session_modules), do: false

  defp canonical_callees(callees) when is_list(callees),
    do: callees |> Enum.sort() |> Enum.dedup()

  defp canonical_callees(other), do: other

  # Drops entries whose caller module is not in `live_modules`. A nil or
  # empty live set disables pruning entirely. Public for direct unit
  # testing; not part of the tracer contract.
  @doc false
  @spec prune_edges(map(), MapSet.t() | nil) :: map()
  def prune_edges(edges, nil) when is_map(edges), do: edges

  def prune_edges(edges, %MapSet{} = live_modules) when is_map(edges) do
    if MapSet.size(live_modules) == 0 do
      edges
    else
      edges
      |> Enum.filter(fn {caller, _callees} -> live_caller?(caller, live_modules) end)
      |> Map.new()
    end
  end

  defp live_caller?({module, _fun, _arity}, live_modules),
    do: MapSet.member?(live_modules, module)

  defp live_caller?(_other, _live_modules), do: false

  defp write_atomic(path, binary) do
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"
    File.write!(tmp, binary)
    File.rename!(tmp, path)
  end
end
