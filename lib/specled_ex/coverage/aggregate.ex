defmodule SpecLedEx.Coverage.Aggregate do
  @moduledoc """
  Ingests an exported `.coverdata` file into a v2 spec coverage envelope
  (aggregate-first design, epic specled_-155).

  `ingest/2` performs a fresh `:cover.stop/0` + `:cover.start/0` +
  `:cover.import/1` cycle — never `:cover.reset/0`, which would corrupt a
  `--cover` tally the caller may be wrapping (see
  `specled.decision.serialized_per_test_coverage` and the epic's OTP-posture
  decision) — then runs two analyse passes per module
  (`:coverage, :line` and `:coverage, :function`) and maps each module to a
  repo-relative source path.

  Modules whose source cannot be resolved to a path under `:root` (not
  loaded in this BEAM, no `:source` compile metadata, or outside the repo —
  e.g. a dependency or OTP/Elixir stdlib module) are excluded from `:files`
  and `:mfas` and counted toward `envelope.degraded`. This lets ingestion of
  a foreign `.coverdata` (the `mix spec.cover.ingest` escape hatch) degrade
  gracefully instead of failing outright.

  This module only builds the envelope (via
  `SpecLedEx.Coverage.Store.build_envelope/1`); it does not persist it —
  callers (the `mix spec.cover.ingest` task, or a future `mix
  spec.cover.test` aggregate mode) call `Store.write_v2/2` themselves.
  """

  alias SpecLedEx.Coverage.{MfaKey, Store}

  @type ingest_opt :: {:root, Path.t()} | {:source, String.t()}

  @doc """
  Ingests the `.coverdata` file at `coverdata_path` into a v2 envelope.

  Options:

    * `:root` — repo root used to compute repo-relative source paths.
      Defaults to `File.cwd!/0`.
    * `:source` — the envelope's `:source` field. Defaults to
      `coverdata_path`.

  Returns:

    * `{:ok, envelope}` — a v2 envelope with `:mode` `:aggregate`.
    * `{:error, :empty_coverage}` — the imported `.coverdata` carries zero
      cover-compiled/imported modules.
    * `{:error, :not_found}` — `coverdata_path` does not exist.
    * `{:error, {:import_failed, reason}}` — `:cover.import/1` refused the
      file (for example malformed/garbage content).
  """
  @spec ingest(Path.t(), [ingest_opt()]) ::
          {:ok, Store.envelope()}
          | {:error, :empty_coverage}
          | {:error, :not_found}
          | {:error, {:import_failed, term()}}
  def ingest(coverdata_path, opts \\ []) when is_binary(coverdata_path) and is_list(opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    source = Keyword.get(opts, :source, coverdata_path)

    _ = cover_stop()
    {:ok, _pid} = ensure_started()

    with :ok <- import_coverdata(coverdata_path) do
      case cover_modules() do
        [] ->
          cover_stop()
          {:error, :empty_coverage}

        modules ->
          {files, mfas, unmapped} = analyse_modules(modules, root)
          cover_stop()
          {:ok, build_envelope(source, files, mfas, unmapped)}
      end
    else
      {:error, _reason} = error ->
        cover_stop()
        error
    end
  end

  defp ensure_started do
    # `:cover` lives in the `:tools` application, which is not guaranteed to
    # already be running in a fresh Mix task invocation (a fresh child BEAM
    # has no reason to have started it, unlike a BEAM that already ran `mix
    # test --cover` in the same process).
    {:ok, _apps} = Application.ensure_all_started(:tools)

    case apply(:cover, :start, []) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp import_coverdata(path) do
    if File.regular?(path) do
      # `:cover.import/1` raises inside the cover server process (surfacing
      # as an ArgumentError from `:erlang.binary_to_term/1`) for content that
      # doesn't even decode as an Erlang term, rather than returning
      # `{:error, reason}` like it does for a well-formed-but-wrong file.
      # Normalize both to the same `{:error, {:import_failed, reason}}` shape.
      case apply(:cover, :import, [String.to_charlist(path)]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:import_failed, reason}}
      end
    else
      {:error, :not_found}
    end
  rescue
    error -> {:error, {:import_failed, error}}
  catch
    :exit, reason -> {:error, {:import_failed, reason}}
  end

  defp cover_stop, do: apply(:cover, :stop, [])

  # `:cover.modules/0` only lists modules Cover-compiled in *this* session; a
  # module that only has imported data (the common case for the escape
  # hatch — a `.coverdata` produced by another run/build) is listed by
  # `:cover.imported_modules/0` instead. Both are analysable via
  # `:cover.analyse/3`, so we union them.
  defp cover_modules do
    (apply(:cover, :modules, []) ++ apply(:cover, :imported_modules, []))
    |> Enum.uniq()
  end

  defp build_envelope(source, files, mfas, unmapped) do
    Store.build_envelope(%{
      mode: :aggregate,
      source: source,
      files: files,
      mfas: mfas,
      degraded: unmapped > 0,
      payload: %{unmapped_modules: unmapped}
    })
  end

  defp analyse_modules(modules, root) do
    {files, mfas, unmapped} =
      Enum.reduce(modules, {[], [], 0}, fn mod, {files_acc, mfas_acc, unmapped_acc} ->
        case source_for(mod, root) do
          {:ok, rel_path} ->
            file_entry = analyse_lines(mod, rel_path)
            mfa_entries = analyse_functions(mod)
            {[file_entry | files_acc], Enum.reverse(mfa_entries) ++ mfas_acc, unmapped_acc}

          :error ->
            {files_acc, mfas_acc, unmapped_acc + 1}
        end
      end)

    {Enum.reverse(files), Enum.reverse(mfas), unmapped}
  end

  defp analyse_lines(mod, rel_path) do
    {:ok, entries} = apply(:cover, :analyse, [mod, :coverage, :line])

    executable = Enum.reject(entries, fn {{_mod, line}, _cov} -> line == 0 end)

    lines_hit =
      executable
      |> Enum.filter(fn {{_mod, _line}, {covered, _not_covered}} -> covered > 0 end)
      |> Enum.map(fn {{_mod, line}, _cov} -> line end)
      |> Enum.sort()

    %{
      file: rel_path,
      module: mod,
      lines_hit: lines_hit,
      lines_total: length(executable)
    }
  end

  defp analyse_functions(mod) do
    {:ok, entries} = apply(:cover, :analyse, [mod, :coverage, :function])

    Enum.map(entries, fn {{m, fun, arity}, {covered, _not_covered}} ->
      %{mfa: MfaKey.format({m, fun, arity}), covered: covered > 0}
    end)
  end

  defp source_for(mod, root) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        case mod.module_info(:compile)[:source] do
          source when is_list(source) -> relative_under_root(List.to_string(source), root)
          source when is_binary(source) -> relative_under_root(source, root)
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp relative_under_root(source_path, root) do
    root = Path.expand(root)
    abs_source = Path.expand(source_path)

    if String.starts_with?(abs_source, root <> "/") do
      {:ok, Path.relative_to(abs_source, root)}
    else
      :error
    end
  end
end
