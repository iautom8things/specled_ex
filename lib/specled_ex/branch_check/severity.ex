defmodule SpecLedEx.BranchCheck.Severity do
  @moduledoc """
  Per-finding severity resolver for branch-guard and validate-time findings.

  Precedence (highest to lowest), with one exception:

      trailer_override > config.severities > per_code_default

  `config.severities` is the union of two distinct config maps — the older
  `branch_guard.severities` (which covers `branch_guard_*` codes) and the
  newer `guardrails.severities` (which covers `append_only/*` and
  `overlap/*` codes). Each map owns a disjoint key namespace; they are kept
  separate on disk so the two surfaces stay legible, but collapse to a
  single config-severity layer for precedence purposes.

  Exception: when a code is silenced via either config map with `:off`, that
  value wins over any trailer override. `:off` is an absorbing state — users
  who explicitly silence a code are not re-noised by per-commit `Spec-Drift:`
  trailers.

  Recognized severity values are `:off`, `:info`, `:warning`, and `:error`.
  Unknown values in config fall back to the per-code default and emit one
  `Logger.warning/1` naming the code and the bad value so misconfiguration is
  visible.

  When `resolve/3` returns `:off`, callers shall treat the finding as not
  produced — no entry in the report, no count toward exit-status math.

  Codes are strings to match YAML config keys and the existing finding
  representation; severity values are atoms.
  """

  require Logger

  @known_severities [:off, :info, :warning, :error]

  @type severity :: :off | :info | :warning | :error
  @type code :: String.t()
  @type severity_map :: %{optional(code()) => severity()}

  @doc """
  Returns the list of known severity atoms.
  """
  @spec known_severities() :: [severity()]
  def known_severities, do: @known_severities

  @doc """
  Resolves the severity for a given finding `code`.

  Options:

    * `:config_severities` — map of `code => severity` from `branch_guard.severities`.
    * `:guardrails_severities` — map of `code => severity` from `guardrails.severities`.
      The two maps are consulted as a single config layer; their key namespaces
      are disjoint by design so at most one map names any given code.
    * `:trailer_override` — map of `code => severity` parsed from `Spec-Drift:`.

  `per_code_default` is the baked-in default severity for the code.

  Unknown atoms encountered in any map trigger `Logger.warning/1` and are
  ignored (treated as if the entry were absent).
  """
  @spec resolve(code(), opts :: keyword() | map(), severity()) :: severity()
  def resolve(code, opts, per_code_default)
      when is_binary(code) and per_code_default in @known_severities do
    config_severities = fetch(opts, :config_severities, %{})
    guardrails_severities = fetch(opts, :guardrails_severities, %{})
    trailer_override = fetch(opts, :trailer_override, %{})

    config_value = sanitized(code, Map.get(config_severities, code), :config)
    guardrails_value = sanitized(code, Map.get(guardrails_severities, code), :guardrails)
    combined_config = guardrails_value || config_value
    trailer_value = sanitized(code, Map.get(trailer_override, code), :trailer)

    cond do
      combined_config == :off -> :off
      not is_nil(trailer_value) -> trailer_value
      not is_nil(combined_config) -> combined_config
      true -> per_code_default
    end
  end

  defp fetch(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp fetch(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp sanitized(_code, nil, _source), do: nil

  defp sanitized(_code, value, _source) when value in @known_severities, do: value

  defp sanitized(code, bad_value, source) do
    Logger.warning(
      "SpecLedEx.BranchCheck.Severity: ignoring unknown severity #{inspect(bad_value)} " <>
        "for code #{inspect(code)} from #{source}. Known values: #{inspect(@known_severities)}."
    )

    nil
  end
end
