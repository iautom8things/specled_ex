defmodule SpecLedEx.Config.BranchGuard do
  @moduledoc """
  Config section for branch-guard severities.

  ## YAML shape

      branch_guard:
        severities:
          branch_guard_realization_drift: info
          spec_requirement_too_short: off

  Each entry is `code => severity` where severity is one of `off`, `info`,
  `warning`, `error` (see `SpecLedEx.BranchCheck.Severity`). Unknown severities
  are rejected and the entry is dropped with a diagnostic.
  """

  alias SpecLedEx.BranchCheck.Severity

  @type t :: %__MODULE__{severities: %{optional(String.t()) => Severity.severity()}}

  defstruct severities: %{}

  @severity_tokens %{
    "off" => :off,
    "info" => :info,
    "warning" => :warning,
    "error" => :error
  }

  @doc "Returns a struct with empty severity overrides."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc "Returns the zoi schema used to validate input."
  def schema do
    Zoi.map(
      %{
        severities:
          Zoi.keyword(Zoi.enum(Map.keys(@severity_tokens)))
          |> Zoi.optional()
      },
      coerce: true
    )
  end

  @doc """
  Parses a raw YAML-derived map into `{struct, diagnostics}`.

  Unknown severity tokens and non-string codes produce diagnostic strings
  and the offending entries are dropped.
  """
  @spec parse(map()) :: {t(), [String.t()]}
  def parse(input) when is_map(input) do
    severities_input =
      case Map.get(input, "severities", Map.get(input, :severities, %{})) do
        map when is_map(map) -> map
        _ -> %{}
      end

    {severities, diagnostics} =
      Enum.reduce(severities_input, {%{}, []}, fn {code, severity_token}, {map, diags} ->
        cond do
          not is_binary(code) ->
            {map, [unknown_code_diag(code) | diags]}

          is_binary(severity_token) and Map.has_key?(@severity_tokens, severity_token) ->
            {Map.put(map, code, Map.fetch!(@severity_tokens, severity_token)), diags}

          severity_token in [:off, :info, :warning, :error] ->
            {Map.put(map, code, severity_token), diags}

          true ->
            {map, [unknown_severity_diag(code, severity_token) | diags]}
        end
      end)

    {%__MODULE__{severities: severities}, Enum.reverse(diagnostics)}
  end

  def parse(_), do: {defaults(), []}

  defp unknown_code_diag(code) do
    "branch_guard.severities key must be a string finding code, got #{inspect(code)}; dropped"
  end

  defp unknown_severity_diag(code, value) do
    "branch_guard.severities.#{code} must be one of off/info/warning/error, got #{inspect(value)}; dropped"
  end
end
