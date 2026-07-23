defmodule SpecLedEx.Coverage.MfaKey do
  @moduledoc """
  Canonical string encoding for a `{module, function, arity}` triple, as
  produced by `:cover.analyse(mod, :coverage, :function)` results.

  `format/1` and `parse/1` round-trip: `parse(format(mfa)) == {:ok, mfa}`.
  `SpecLedEx.Coverage.Aggregate` uses this to key the `:mfas` entries in the
  v2 coverage envelope; `SpecLedEx.Review.CoverageClosure` (a later epic
  ticket) parses the same string format back into `{module, function,
  arity}` to cross-reference against realization closures.
  """

  @type mfa_ref :: {module(), atom(), non_neg_integer()}

  @doc """
  Formats `{module, function, arity}` as `"Mod.fun/arity"`.
  """
  @spec format(mfa_ref()) :: String.t()
  def format({mod, fun, arity})
      when is_atom(mod) and is_atom(fun) and is_integer(arity) and arity >= 0 do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  @doc """
  Parses a `"Mod.fun/arity"` string back into `{module, function, arity}`.

  Returns `{:error, :invalid_mfa_key}` for malformed input.
  """
  @spec parse(String.t()) :: {:ok, mfa_ref()} | {:error, :invalid_mfa_key}
  def parse(string) when is_binary(string) do
    with [prefix, arity_str] <- String.split(string, "/"),
         {arity, ""} <- Integer.parse(arity_str),
         parts <- String.split(prefix, "."),
         true <- length(parts) >= 2,
         {module_parts, [fun_name]} <- Enum.split(parts, -1),
         true <- module_parts != [] and Enum.all?(module_parts, &valid_module_part?/1),
         true <- fun_name != "" do
      {:ok, {Module.concat(module_parts), String.to_atom(fun_name), arity}}
    else
      _ -> {:error, :invalid_mfa_key}
    end
  end

  defp valid_module_part?(part), do: String.match?(part, ~r/^[A-Z][A-Za-z0-9_]*$/)
end
