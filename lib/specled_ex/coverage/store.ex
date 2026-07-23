defmodule SpecLedEx.Coverage.Store do
  @moduledoc """
  Reader/writer for the per-test coverage artifact at
  `.spec/_coverage/per_test.coverdata`.

  Records are maps with fields `:test_id`, `:file`, `:lines_hit`, `:tags`, and
  `:test_pid`, encoded as Erlang Term Format (ETF). The schema version is
  implicit; downstream consumers (triangulation) bump their `hasher_version`
  when the layout changes.

  `build_records/1` is a pure helper for tests that need to author artifacts
  without instantiating a formatter or running `:cover`.
  """

  alias SpecLedEx.Coverage

  @type record :: %{
          required(:test_id) => String.t(),
          required(:file) => String.t(),
          required(:lines_hit) => [non_neg_integer()],
          required(:tags) => map(),
          required(:test_pid) => pid()
        }

  @doc """
  On-disk path for the per-test artifact.
  """
  @spec default_path() :: Path.t()
  def default_path, do: Coverage.default_artifact_path()

  @doc """
  Builds a list of normalized per-test records from loosely-typed Elixir
  input. Each input entry must carry the five required fields; extra keys are
  dropped. Order is preserved.
  """
  @spec build_records([map()]) :: [record()]
  def build_records(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        test_id: fetch!(entry, :test_id),
        file: fetch!(entry, :file),
        lines_hit: fetch!(entry, :lines_hit),
        tags: fetch!(entry, :tags),
        test_pid: fetch!(entry, :test_pid)
      }
    end)
  end

  @doc """
  Writes records to `path` as ETF. Creates the parent directory if missing.
  """
  @spec write([record()], Path.t()) :: :ok
  def write(records, path) when is_list(records) and is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(records))
    :ok
  end

  @doc """
  Reads and decodes the ETF artifact at `path`. Returns the record list.
  """
  @spec read(Path.t()) :: [record()]
  def read(path) when is_binary(path) do
    path
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  # ---------------------------------------------------------------------
  # v2 envelope (epic specled_-155, aggregate-first spec coverage)
  #
  # The bare v1 list above has no in-band version marker. v2 replaces it
  # with a versioned envelope so the artifact can be validated and evolved
  # in-band:
  #
  #     %{
  #       version: 2,
  #       mode: :aggregate | :per_test,
  #       generated_at: DateTime.t(),
  #       source: String.t(),
  #       files: [term()],
  #       mfas: [term()],
  #       payload: term(),
  #       degraded: boolean()
  #     }
  #
  # This module owns the envelope container, validation, and read/write
  # only. It does not define the per-entry schema for `:files` / `:mfas` /
  # `:payload` — those are the concern of the ingestion logic
  # (`SpecLedEx.Coverage.Aggregate`, a later ticket in the epic).
  #
  # v2 targets the same on-disk path as v1 (`.spec/_coverage/per_test.coverdata`
  # by default) so a pre-upgrade v1 artifact left over at that path is
  # detected and rejected as `:legacy_artifact` rather than silently
  # misinterpreted — see Decision 5 in the epic: legacy artifacts are never
  # auto-migrated or deleted; the operator re-runs `mix spec.cover.test`.
  #
  # Every `write_v2/2` call (success or refusal) also (re)writes a
  # `last_run.status` sidecar next to the artifact, read back via
  # `read_status/1`, so callers can tell whether the last capture attempt
  # actually produced usable coverage without decoding the full artifact.
  # ---------------------------------------------------------------------

  @v2_version 2
  @status_filename "last_run.status"
  @legacy_message "Legacy per-test coverage artifact detected (pre-v2 format)." <>
                    " specled does not auto-migrate or delete it — re-run" <>
                    " `mix spec.cover.test` to regenerate a v2 artifact."

  @type mode :: :aggregate | :per_test

  @type envelope :: %{
          version: pos_integer(),
          mode: mode(),
          generated_at: DateTime.t(),
          source: String.t(),
          files: [term()],
          mfas: [term()],
          payload: term(),
          degraded: boolean()
        }

  @doc """
  Builds a v2 envelope from loosely-typed fields.

  `:mode`, `:source`, `:files`, `:mfas`, and `:payload` are required.
  `:generated_at` defaults to `DateTime.utc_now/0`; `:degraded` defaults to
  `false`. `:version` is always #{@v2_version} and cannot be overridden.
  """
  @spec build_envelope(map()) :: envelope()
  def build_envelope(fields) when is_map(fields) do
    %{
      version: @v2_version,
      mode: fetch!(fields, :mode),
      generated_at: Map.get(fields, :generated_at, DateTime.utc_now()),
      source: fetch!(fields, :source),
      files: fetch!(fields, :files),
      mfas: fetch!(fields, :mfas),
      payload: fetch!(fields, :payload),
      degraded: Map.get(fields, :degraded, false)
    }
  end

  @doc """
  Writes a v2 envelope to `path` as ETF.

  Refuses (returns `{:error, :empty_files}`) when `envelope.files == []` —
  an envelope with no file coverage at all is never written, since it would
  otherwise silently pass as "captured, but nothing." Every call, whether it
  succeeds or is refused, (re)writes the `last_run.status` sidecar next to
  `path` — see `read_status/1`.

  Raises `ArgumentError` if `envelope` is missing a required v2 field; this
  is a programmer error (malformed input), not a runtime refusal.
  """
  @spec write_v2(envelope(), Path.t()) :: :ok | {:error, :empty_files}
  def write_v2(%{} = envelope, path) when is_binary(path) do
    validate_envelope!(envelope)

    if envelope.files == [] do
      write_status(path, {:refused, :empty_files})
      {:error, :empty_files}
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :erlang.term_to_binary(envelope))
      write_status(path, {:ok, envelope_stats(envelope)})
      :ok
    end
  end

  @doc """
  Reads and decodes the v2 artifact at `path`.

  Returns:

    * `{:ok, envelope}` — a well-formed v2 envelope.
    * `{:error, :legacy_artifact, message}` — the artifact decodes as a bare
      list (the v1 on-disk shape). `message` names the re-run command
      (`mix spec.cover.test`); per Decision 5, specled never auto-migrates
      or deletes it.
    * `{:error, :invalid_artifact}` — the file is missing, undecodable, or
      decodes to a term that is neither a v1 list nor a valid v2 envelope
      map.
  """
  @spec read_v2(Path.t()) ::
          {:ok, envelope()} | {:error, :legacy_artifact, String.t()} | {:error, :invalid_artifact}
  def read_v2(path) when is_binary(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, term} <- safe_decode(bin) do
      classify_v2(term)
    else
      _ -> {:error, :invalid_artifact}
    end
  end

  @doc """
  Reads the `last_run.status` sidecar for the v2 artifact at `path`
  (the sidecar lives alongside `path`, not at `path` itself).

  Returns `{:ok, stats}` when the last `write_v2/2` call succeeded, or
  `{:refused, reason}` when it was refused, the sidecar is missing, or the
  sidecar cannot be decoded.
  """
  @spec read_status(Path.t()) :: {:ok, map()} | {:refused, term()}
  def read_status(path) when is_binary(path) do
    with {:ok, bin} <- File.read(status_path(path)),
         {:ok, term} <- safe_decode(bin) do
      case term do
        {:ok, stats} -> {:ok, stats}
        {:refused, reason} -> {:refused, reason}
        _ -> {:refused, :invalid_status}
      end
    else
      _ -> {:refused, :not_found}
    end
  end

  @v2_required_fields [
    :version,
    :mode,
    :generated_at,
    :source,
    :files,
    :mfas,
    :payload,
    :degraded
  ]

  defp validate_envelope!(envelope) do
    Enum.each(@v2_required_fields, fn key ->
      unless Map.has_key?(envelope, key) do
        raise ArgumentError, "v2 envelope missing required field #{inspect(key)}"
      end
    end)

    unless is_list(envelope.files), do: raise(ArgumentError, "envelope :files must be a list")
    unless is_list(envelope.mfas), do: raise(ArgumentError, "envelope :mfas must be a list")
    :ok
  end

  defp classify_v2(%{version: @v2_version} = envelope) do
    if Enum.all?(@v2_required_fields, &Map.has_key?(envelope, &1)) do
      {:ok, envelope}
    else
      {:error, :invalid_artifact}
    end
  end

  defp classify_v2(term) when is_list(term), do: {:error, :legacy_artifact, @legacy_message}
  defp classify_v2(_other), do: {:error, :invalid_artifact}

  defp safe_decode(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    ArgumentError -> :error
  end

  defp write_status(artifact_path, outcome) do
    path = status_path(artifact_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(outcome))
    :ok
  end

  defp status_path(artifact_path), do: Path.join(Path.dirname(artifact_path), @status_filename)

  defp envelope_stats(envelope) do
    %{
      mode: envelope.mode,
      generated_at: envelope.generated_at,
      file_count: length(envelope.files),
      mfa_count: length(envelope.mfas),
      degraded: envelope.degraded
    }
  end

  defp fetch!(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end
end
