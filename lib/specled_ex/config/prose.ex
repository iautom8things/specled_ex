defmodule SpecLedEx.Config.Prose do
  @moduledoc """
  Config section for the prose-rot guard, and the guard itself.

  ## Thresholds

      prose:
        min_chars: 40
        min_words: 6

  Missing keys fall back to defaults. Negative or non-integer values are
  rejected by the zoi schema; `parse/1` reports the rejection as a diagnostic
  and falls back to defaults.

  ## Finding

  `findings/3` walks subjects and emits one `spec_requirement_too_short`
  finding per `must` requirement whose statement falls below the configured
  char-count OR word-count threshold. The finding severity is resolved via
  `SpecLedEx.BranchCheck.Severity.resolve/3` with a per-code default of
  `:info`; setting that code to `:off` in `config.severities` suppresses the
  finding entirely. Requirements with priority other than `must` are exempt.
  """

  alias SpecLedEx.BranchCheck.Severity

  @default_min_chars 40
  @default_min_words 6

  @type t :: %__MODULE__{min_chars: non_neg_integer(), min_words: non_neg_integer()}

  defstruct min_chars: @default_min_chars, min_words: @default_min_words

  @doc "Returns a struct with the documented defaults."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc "Returns the zoi schema used to validate input."
  def schema do
    Zoi.map(
      %{
        min_chars: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional(),
        min_words: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Parses a raw YAML-derived map into `{struct, diagnostics}`.

  Diagnostics are plain strings describing each rejected field. Rejected
  fields fall back to defaults; missing fields fall back to defaults without
  diagnostics.
  """
  @spec parse(map()) :: {t(), [String.t()]}
  def parse(input) when is_map(input) do
    normalized =
      input
      |> Enum.map(fn {k, v} -> {normalize_key(k), v} end)
      |> Enum.into(%{})

    {min_chars, chars_diag} =
      validate_integer(Map.get(normalized, :min_chars), @default_min_chars, "min_chars")

    {min_words, words_diag} =
      validate_integer(Map.get(normalized, :min_words), @default_min_words, "min_words")

    diagnostics = Enum.reject([chars_diag, words_diag], &is_nil/1)

    {%__MODULE__{min_chars: min_chars, min_words: min_words}, diagnostics}
  end

  def parse(_), do: {defaults(), []}

  defp normalize_key(k) when is_atom(k), do: k

  defp normalize_key(k) when is_binary(k) do
    case k do
      "min_chars" -> :min_chars
      "min_words" -> :min_words
      _ -> nil
    end
  end

  defp normalize_key(_), do: nil

  defp validate_integer(nil, default, _field), do: {default, nil}

  defp validate_integer(value, _default, _field) when is_integer(value) and value >= 0,
    do: {value, nil}

  defp validate_integer(value, default, field) do
    {default,
     "prose.#{field} must be a non-negative integer, got #{inspect(value)}; using default #{default}"}
  end

  @finding_code "spec_requirement_too_short"
  @per_code_default :info

  @doc "Returns the finding code emitted by `findings/3`."
  @spec finding_code() :: String.t()
  def finding_code, do: @finding_code

  @doc "Returns the per-code default severity used by `Severity.resolve/3`."
  @spec per_code_default() :: Severity.severity()
  def per_code_default, do: @per_code_default

  @doc """
  Walks the `index`'s subjects and returns `spec_requirement_too_short`
  findings for each `must` requirement whose statement falls below the
  threshold.

  `config_severities` is the user's severity override map (typically
  `config.branch_guard.severities`). Pass `%{}` for defaults.
  """
  @spec findings(map(), t(), %{optional(String.t()) => Severity.severity()}) :: [map()]
  def findings(index, %__MODULE__{} = prose, config_severities)
      when is_map(index) and is_map(config_severities) do
    severity =
      Severity.resolve(
        @finding_code,
        [config_severities: config_severities],
        @per_code_default
      )

    if severity == :off do
      []
    else
      index
      |> Map.get("subjects", [])
      |> List.wrap()
      |> Enum.flat_map(&subject_findings(&1, prose, severity))
    end
  end

  defp subject_findings(subject, %__MODULE__{} = prose, severity) when is_map(subject) do
    file = string_field(subject, "file")
    subject_id = subject |> Map.get("meta", %{}) |> get_field("id") || file

    subject
    |> Map.get("requirements", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn req -> get_field(req, "priority") == "must" end)
    |> Enum.flat_map(fn req ->
      id = get_field(req, "id")
      statement = get_field(req, "statement") || ""
      dims = failing_dimensions(statement, prose)

      case {id, dims} do
        {nil, _} -> []
        {_id, []} -> []
        {id, dims} -> [short_finding(severity, id, dims, subject_id, file)]
      end
    end)
  end

  defp subject_findings(_subject, _prose, _severity), do: []

  defp failing_dimensions(statement, %__MODULE__{min_chars: mc, min_words: mw}) do
    chars = String.length(String.trim(statement))
    words = statement |> String.split(~r/\s+/, trim: true) |> length()

    []
    |> maybe_add(chars < mc, "chars")
    |> maybe_add(words < mw, "words")
  end

  defp maybe_add(list, true, label), do: [label | list]
  defp maybe_add(list, false, _label), do: list

  defp short_finding(severity, req_id, dims, subject_id, file) do
    dims_label = dims |> Enum.reverse() |> Enum.join(",")

    %{
      "severity" => Atom.to_string(severity),
      "code" => @finding_code,
      "message" => "Requirement statement too short (#{dims_label}): #{req_id}",
      "subject_id" => subject_id,
      "file" => file
    }
  end

  defp string_field(item, key) when is_map(item) do
    case get_field(item, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp get_field(item, key) when is_map(item) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(item, key, if(atom_key, do: Map.get(item, atom_key)))
  end

  defp get_field(_, _), do: nil
end
