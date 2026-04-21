defmodule SpecLedEx.BranchCheck.Trailer do
  @moduledoc """
  Parses `Spec-Drift:` git trailers and projects them into a severity override
  map suitable for `SpecLedEx.BranchCheck.Severity.resolve/3`.

  ## Vocabulary

  Recognized trailer values are:

    * `refactor`  — downgrades `branch_guard_realization_drift` to `:info`
    * `docs_only` — downgrades `branch_guard_unmapped_change` to `:info`
    * `test_only` — downgrades `branch_guard_missing_subject_update` to `:info`
    * `<code>=<severity>` — explicit per-code override, e.g.
      `branch_guard_realization_drift=info`. Severity must be one of
      `off`, `info`, `warning`, `error`.

  Unknown tokens are ignored and reported via the `:warnings` list so mistyped
  trailers are visible to the author rather than silently dropped.

  ## Scope: `base..HEAD`, not HEAD-only

  `read/2` shells `git log <base>..HEAD --format=%B` and returns the union of
  parsed overrides across every commit in the range. HEAD-only scanning is
  explicitly wrong and not supported — CI often sees squash or merge commits
  where the trailer lives one commit deep. See
  `.spec/decisions/specled.decision.spec_drift_base_to_head.md`.

  ## Self-report

  Trailers are a cooperative self-report. `read/2` does not verify signatures
  or authorship. This is suited to single-author and small-team workflows;
  larger teams should pair trailers with code review.

  ## Codes

  Codes in the returned override map are strings (e.g.
  `"branch_guard_realization_drift"`) to avoid creating atoms from untrusted
  commit-message input.
  """

  alias SpecLedEx.BranchCheck.Severity

  @trailer_prefix "Spec-Drift:"

  @preset_mappings %{
    "refactor" => %{"branch_guard_realization_drift" => :info},
    "docs_only" => %{"branch_guard_unmapped_change" => :info},
    "test_only" => %{"branch_guard_missing_subject_update" => :info}
  }

  @severity_tokens %{
    "off" => :off,
    "info" => :info,
    "warning" => :warning,
    "error" => :error
  }

  @type override_map :: %{optional(String.t()) => Severity.severity()}
  @type parse_result :: %{overrides: override_map(), warnings: [String.t()]}

  @doc "Returns the list of preset vocabulary tokens accepted by `parse/1`."
  @spec preset_tokens() :: [String.t()]
  def preset_tokens, do: Map.keys(@preset_mappings)

  @doc """
  Parses one or more commit messages into an override map.

  Returns `%{overrides: %{code => severity}, warnings: [String.t()]}`. Trailer
  lines take the form `Spec-Drift: <token>[, <token>...]`.
  """
  @spec parse(binary()) :: parse_result()
  def parse(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&trailer_tokens/1)
    |> Enum.reduce(%{overrides: %{}, warnings: []}, &apply_token/2)
    |> finalize()
  end

  @doc """
  Reads `git log <base>..HEAD --format=%B` in `root` and returns the union of
  parsed overrides across every commit in the range.
  """
  @spec read(String.t(), String.t()) :: parse_result()
  def read(root, base) when is_binary(root) and is_binary(base) do
    case System.cmd(
           "git",
           ["-C", root, "log", "#{base}..HEAD", "--format=%B"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse(output)
      {_output, _exit_code} -> %{overrides: %{}, warnings: []}
    end
  end

  defp trailer_tokens(line) do
    trimmed = String.trim_leading(line)

    if String.starts_with?(trimmed, @trailer_prefix) do
      trimmed
      |> String.replace_prefix(@trailer_prefix, "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
  end

  defp apply_token(token, acc) do
    cond do
      Map.has_key?(@preset_mappings, token) ->
        merge_overrides(acc, Map.fetch!(@preset_mappings, token))

      String.contains?(token, "=") ->
        apply_pair(token, acc)

      true ->
        add_warning(acc, unknown_token_message(token))
    end
  end

  defp apply_pair(token, acc) do
    [code, severity_str] =
      token
      |> String.split("=", parts: 2)
      |> Enum.map(&String.trim/1)

    cond do
      code == "" ->
        add_warning(acc, unknown_token_message(token))

      not Map.has_key?(@severity_tokens, severity_str) ->
        add_warning(acc, "Spec-Drift: unknown severity in #{inspect(token)}")

      true ->
        merge_overrides(acc, %{code => Map.fetch!(@severity_tokens, severity_str)})
    end
  end

  defp merge_overrides(%{overrides: overrides} = acc, new) do
    %{acc | overrides: Map.merge(overrides, new)}
  end

  defp add_warning(%{warnings: warnings} = acc, msg) do
    %{acc | warnings: [msg | warnings]}
  end

  defp finalize(%{warnings: warnings} = acc) do
    %{acc | warnings: warnings |> Enum.reverse() |> Enum.uniq()}
  end

  defp unknown_token_message(token), do: "Spec-Drift: unknown token #{inspect(token)}"
end
