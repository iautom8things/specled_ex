defmodule SpecLedEx.Validator.RealizedByDedupCheck do
  @moduledoc """
  Emits `realized_by_redundant_dup` findings for subjects whose `realized_by`
  lists the same entry under both `api_boundary` and `implementation`.

  Implements `specled.realized_by.redundant_dup_warning`:

  > `mix spec.validate` shall emit a `realized_by_redundant_dup` warning for
  > any subject where the same entry (MFA or bare module) appears in both
  > `api_boundary` and `implementation`. The finding shall name the subject,
  > the entry, and a one-line remediation pointer. The severity shall be
  > `warning` (hardcoded).

  The actual duplicate detection is delegated to
  `SpecLedEx.Validator.RealizedByDedupe.duplicates/1` — the shared seam that
  the future `mix spec.dedup_realized_by` task also calls (see
  `specled.realized_by.dedup_check_shared_seam`).

  Per-form message text (per the spec requirement):

    * **MFA-form** (`"Mod.fun/arity"`): notes that api_boundary's hash is a
      strict subset of implementation's, so the api_boundary line is
      redundant.
    * **Bare-module form** (`"Mod"`): notes that both tiers continue to
      track the module via separate head-union (api_boundary) and full-union
      (implementation) hashes — the duplication is still redundant because
      the implication keeps api_boundary tracking the module without the
      explicit listing.

  Severity is hardcoded to `:warning`; per Decision 7 of
  `specled.decision.realized_by_tier_implication`, no config plumbing for
  this code in v1. The function accepts a `severity` argument so the future
  dedup task can borrow the same finding shape with a different severity if
  ever needed; production callers should pass `:warning` (or omit the arg).
  """

  alias SpecLedEx.Realization.Binding
  alias SpecLedEx.Validator.RealizedByDedupe

  @finding_code "realized_by_redundant_dup"
  @remediation "run mix spec.dedup_realized_by to remove the redundant api_boundary line"

  @doc "Returns the finding code emitted by `findings/2`."
  @spec finding_code() :: String.t()
  def finding_code, do: @finding_code

  @doc """
  Walks subjects in `index` and returns one `realized_by_redundant_dup`
  finding per `{subject, entry}` pair where the entry appears in both
  `api_boundary` and `implementation`.

  Severity is hardcoded `:warning` by default; callers may pass another
  level but production wiring (`mix spec.validate`) does not.
  """
  @spec findings(map(), atom()) :: [map()]
  def findings(index, severity \\ :warning) when is_map(index) and is_atom(severity) do
    index
    |> Map.get("subjects", [])
    |> List.wrap()
    |> Enum.flat_map(&subject_findings(&1, severity))
  end

  defp subject_findings(subject, severity) when is_map(subject) do
    RealizedByDedupe.duplicates(subject)
    |> Enum.map(fn {_tier_pair, entry} -> finding(severity, subject, entry) end)
  end

  defp subject_findings(_subject, _severity), do: []

  defp finding(severity, subject, entry) do
    file = string_field(subject, "file")
    subject_id = subject_id(subject) || file

    %{
      "severity" => Atom.to_string(severity),
      "code" => @finding_code,
      "message" => message_for(entry, subject_id),
      "subject_id" => subject_id,
      "file" => file
    }
  end

  defp message_for(entry, subject_id) do
    case classify_entry(entry) do
      :mfa ->
        "realized_by entry #{inspect(entry)} on subject #{subject_id} appears " <>
          "in both api_boundary and implementation; the api_boundary hash is a " <>
          "strict subset of implementation's, so the api_boundary line is redundant " <>
          "(implication still tracks it). #{@remediation}."

      :bare_module ->
        "realized_by entry #{inspect(entry)} on subject #{subject_id} appears " <>
          "in both api_boundary and implementation; both tiers continue to track " <>
          "the module via separate head-union (api_boundary) and full-union " <>
          "(implementation) hashes, so the explicit api_boundary line is redundant " <>
          "(implication still tracks it). #{@remediation}."

      :unknown ->
        "realized_by entry #{inspect(entry)} on subject #{subject_id} appears " <>
          "in both api_boundary and implementation; the api_boundary listing is " <>
          "redundant under the implementation ⟹ api_boundary implication. " <>
          "#{@remediation}."
    end
  end

  defp classify_entry(entry) when is_binary(entry) do
    case Binding.parse(entry) do
      {:ok, {_mod, _fun, _arity}} -> :mfa
      {:ok, {:module, _mod}} -> :bare_module
      _ -> :unknown
    end
  end

  defp classify_entry(_), do: :unknown

  defp subject_id(subject) when is_map(subject) do
    case Map.get(subject, "meta") || Map.get(subject, :meta) do
      nil -> nil
      meta -> get_field(meta, "id")
    end
  end

  defp subject_id(_), do: nil

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
