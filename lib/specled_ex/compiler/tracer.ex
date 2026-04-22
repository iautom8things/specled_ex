defmodule SpecLedEx.Compiler.Tracer do
  # covers: specled.compiler_tracer.single_file_cap
  @moduledoc """
  `Code.Tracer` that captures MFA-level callee edges during compile.

  Registered in `mix.exs` via `elixirc_options: [tracers: [#{inspect(__MODULE__)}]]`,
  this tracer receives `:remote_function`, `:imported_function`, and
  `:imported_macro` events during compilation, accumulating edges
  `{caller_module, caller_fun, caller_arity} => [{callee_module, callee_fun, callee_arity}]`.

  On each `:on_module` event, the accumulated edges for all modules compiled so far
  are serialized as Erlang External Term Format (ETF) to
  `_build/\#{Mix.env()}/.spec/xref_mfa.etf`. Callers read this file directly via
  `:erlang.binary_to_term/1` — no subprocess.

  The tracer is resilient to being invoked in parallel by multiple compiler worker
  processes: edges accumulate in a single public named ETS table, and manifest
  writes use `File.write!/2`. Because every write emits the full table contents,
  the final file state reflects every observed edge regardless of which worker
  wrote last.

  See `specled.decision.custom_compile_tracer` for the rationale behind this
  approach versus post-hoc `mix xref graph --format json` (which does not exist).

  ## Note on the tracer contract

  Elixir's tracer API is structural, not a formal `@behaviour`: any module that
  exports `trace/2` can be registered in `elixirc_options[:tracers]`. We therefore
  document the contract here rather than annotate with `@impl`.
  """

  @table :specled_compiler_tracer_edges

  @manifest_subpath Path.join(".spec", "xref_mfa.etf")

  @doc false
  @spec table_name() :: atom()
  def table_name, do: @table

  @doc false
  @spec ensure_table() :: atom()
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :public,
            :named_table,
            :bag,
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

    @table
  end

  # Parallel compiler workers create and use the table, but each worker is
  # short-lived — on death the table would be destroyed unless ownership
  # transfers. `:application_controller` is started by the kernel app and lives
  # for the entire VM, so it's a safe heir: the table persists across worker
  # lifecycles for the full compile. Falls back to `self/0` if the controller
  # is somehow unavailable (unusual — only during very early VM boot).
  defp heir_pid do
    case :erlang.whereis(:application_controller) do
      pid when is_pid(pid) -> pid
      _ -> self()
    end
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
  events; flushes the table to ETF on `:on_module`.
  """
  @spec trace(atom() | tuple(), Macro.Env.t()) :: :ok
  def trace(:start, _env) do
    ensure_table()
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

  defp flush(_env) do
    ensure_table()
    path = manifest_path()
    File.mkdir_p!(Path.dirname(path))

    edges =
      :ets.tab2list(@table)
      |> Enum.reduce(%{}, fn {caller, callee}, acc ->
        Map.update(acc, caller, [callee], fn list ->
          if callee in list, do: list, else: [callee | list]
        end)
      end)

    File.write!(path, :erlang.term_to_binary(edges))
    :ok
  end
end
