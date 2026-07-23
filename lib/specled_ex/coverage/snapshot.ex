defmodule SpecLedEx.Coverage.Snapshot do
  @moduledoc """
  Per-module line-count snapshots for the `--per-test` coverage engine, and
  the pure diff between two of them.

  ## Read-only invariant (binding, empirically verified)

  This module NEVER calls `:cover.reset/0` (nor `:code.reset_coverage/1`).
  Both zero the counters the wrapped `mix test --cover` report ultimately
  reads, which would silently corrupt that report. Per-test attribution
  instead comes from diffing two cumulative snapshots (`diff/2`): every
  count in a snapshot is a running total since the module was loaded (or
  since the last drain performed by someone else — see below), never reset
  by this module.

  ## Native vs. classic, and why native is safe

  `runtime_mode/0` gates on `:code.coverage_support/0`. On a runtime that
  supports it (OTP >= 27, decision 4 recommends >= 27.2; never hard-gated —
  `native_snapshot/1` catches the `ArgumentError` a module that isn't
  cover-compiled raises and treats it as zero coverage for that module,
  so an unsupported or partially-instrumented runtime degrades to empty
  data for that module rather than crashing the run), `native_snapshot/1`
  reads coverage directly via `:code.get_coverage(:line, Module)` — a BIF
  read of the module's own native counters, with no round trip through the
  `:cover` coordinator process and no whole-table ETS scan. `classic_snapshot/1`
  is the fallback: `:cover.analyse(Module, :calls, :line)` per module in
  `scope_modules/0` (looping per module is ~6.5x cheaper than one
  `:cover.analyse(:_, :calls, :line)` whole-table call, since the latter
  walks every module `:cover` knows about, not just the ones this run cares
  about).

  This was empirically probed in-worktree (OTP 27.2 / erts-15.2) before
  freezing the decoder, because the two read paths are not equivalent:

    * `:code.coverage_support/0` => `true`; cover-compiling a module (as
      `mix test --cover` already does) is enough to put it in
      `:line_counters` mode with no extra setup on this module's part —
      `:code.get_coverage_mode/1` reported `:line_counters` immediately
      after `:cover.compile_beam/1`, before this module ever called
      `:code.set_coverage_mode/1`.
    * `:code.get_coverage(:line, Module)` returns a flat `[{line, count}]`
      list (ascending line order observed, no synthetic `{Module, 0}`
      entry the way `:cover.analyse/3` includes) and is a pure, idempotent
      read: calling it repeatedly with no other `:cover` activity in
      between returns byte-identical results every time.
    * `:cover.analyse/3`, by contrast, is NOT a pure read: calling it
      drains the same native line counters back toward zero as a side
      effect (confirmed empirically — a `:code.get_coverage(:line, _)`
      call immediately after a `:cover.analyse/3` call on the same module
      reads all zeros), then folds the drained delta into `:cover`'s own
      persistent, summing tally. `:cover.analyse/3`'s *return value* stays
      correctly cumulative regardless of how many times it (or anything
      else) has drained the counters in between — only the raw native
      counters reset on drain, never `:cover`'s own running total.
    * Consequence: our own repeated `native_snapshot/1` calls never
      perturb `:cover`'s eventual report (confirmed: `:cover.analyse/3`
      called after several intervening `native_snapshot/1` reads still
      reports the full, undiminished cumulative count) — satisfying the
      cumulative-parity requirement. But if anything ELSE calls
      `:cover.analyse/3` (or otherwise drains) between two of *our* native
      reads, our next read legitimately comes back lower than our last
      cached snapshot for that module. `diff/2` treats that as a
      `"counters externally harvested"` diagnostic rather than a
      negative/garbage delta — see below.

  ## diff/2

  Given a previous and current snapshot (each `%{module => [{line,
  count}]}`), returns `{hits_by_module, diagnostics}`:

    * a line is a hit for this diff window only if its count strictly
      increased (`curr > prev`, `prev` defaulting to `0` for a line or
      module unseen in `prev`) — an unchanged count is simply "not
      touched in this window", not a hit;
    * a strictly *decreased* count never becomes a (negative) hit; it is
      recorded as a diagnostic (`counters externally harvested`) instead,
      naming the module, line, and the two counts observed. Callers use a
      non-empty diagnostics list to mark the affected artifact `degraded`.
  """

  alias SpecLedEx.Coverage

  @type line :: pos_integer()
  @type count :: non_neg_integer()
  @type module_snapshot :: %{module() => [{line(), count()}]}
  @type diagnostic :: %{
          reason: :counters_externally_harvested,
          module: module(),
          line: line(),
          prev: count(),
          curr: count()
        }

  @doc """
  `:native` when the runtime supports native coverage
  (`:code.coverage_support/0`), otherwise `:classic`. Never hard-gates on a
  specific OTP version (decision 4) — an older runtime simply reports
  `:classic` here.
  """
  @spec runtime_mode() :: :native | :classic
  def runtime_mode do
    if coverage_support?(), do: :native, else: :classic
  end

  defp coverage_support? do
    :code.coverage_support()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  The module scope a snapshot is taken over. Delegates to
  `SpecLedEx.Coverage.cover_modules_safe/0` (already rescues/catches around
  `:cover.modules/0`).
  """
  @spec scope_modules() :: [module()]
  def scope_modules, do: Coverage.cover_modules_safe()

  @doc """
  Takes a snapshot over `modules` using `mode` (`runtime_mode/0`'s result).
  """
  @spec take(:native | :classic, [module()]) :: module_snapshot()
  def take(:native, modules) when is_list(modules), do: native_snapshot(modules)
  def take(:classic, modules) when is_list(modules), do: classic_snapshot(modules)

  @doc """
  Native per-module line snapshot via `:code.get_coverage(:line, Module)`.

  Each module is read inside its own try/catch: a module that is not
  loaded, or is loaded but was never cover-compiled (mode `:none`), raises
  `ArgumentError` from the BIF — caught and treated as "no data yet" (`[]`)
  for that module rather than aborting the whole snapshot. This is the
  mitigation decision 4 relies on instead of a hard OTP version gate.
  """
  @spec native_snapshot([module()]) :: module_snapshot()
  def native_snapshot(modules) when is_list(modules) do
    Map.new(modules, fn mod -> {mod, native_lines(mod)} end)
  end

  defp native_lines(mod) do
    case :code.get_coverage(:line, mod) do
      lines when is_list(lines) -> lines
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Classic per-module line snapshot via `:cover.analyse(Module, :calls,
  :line)`, looped per module in `modules` rather than one whole-table
  `:cover.analyse(:_, :calls, :line)` call.

  Normalizes `:cover.analyse/3`'s `{{Module, Line}, Count}` result shape
  down to native's `{Line, Count}` shape (dropping the module from the key
  since it is already the map key one level up) and drops the synthetic
  `{Module, 0}` entry `:cover` reports, so `diff/2` runs identically over
  either mode's output.
  """
  @spec classic_snapshot([module()]) :: module_snapshot()
  def classic_snapshot(modules) when is_list(modules) do
    Map.new(modules, fn mod -> {mod, classic_lines(mod)} end)
  end

  defp classic_lines(mod) do
    case apply(:cover, :analyse, [mod, :calls, :line]) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn {{_mod, line}, _count} -> line > 0 end)
        |> Enum.map(fn {{_mod, line}, count} -> {line, count} end)

      _not_cover_compiled_or_other ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Diffs two module snapshots. Returns `{hits_by_module, diagnostics}` —
  see the moduledoc for the strictly-increased-only and
  externally-harvested-diagnostic semantics.
  """
  @spec diff(module_snapshot(), module_snapshot()) :: {%{module() => [line()]}, [diagnostic()]}
  def diff(prev, curr) when is_map(prev) and is_map(curr) do
    Enum.reduce(curr, {%{}, []}, fn {mod, lines}, {hits, diags} ->
      prev_lines = prev |> Map.get(mod, []) |> Map.new()
      {mod_hits, mod_diags} = diff_module_lines(mod, lines, prev_lines)

      hits = if mod_hits == [], do: hits, else: Map.put(hits, mod, mod_hits)
      {hits, mod_diags ++ diags}
    end)
  end

  defp diff_module_lines(mod, curr_lines, prev_by_line) do
    Enum.reduce(curr_lines, {[], []}, fn {line, curr_count}, {hits, diags} ->
      prev_count = Map.get(prev_by_line, line, 0)

      cond do
        curr_count > prev_count ->
          {[line | hits], diags}

        curr_count < prev_count ->
          diagnostic = %{
            reason: :counters_externally_harvested,
            module: mod,
            line: line,
            prev: prev_count,
            curr: curr_count
          }

          {hits, [diagnostic | diags]}

        true ->
          {hits, diags}
      end
    end)
    |> then(fn {hits, diags} -> {Enum.sort(hits), diags} end)
  end
end
