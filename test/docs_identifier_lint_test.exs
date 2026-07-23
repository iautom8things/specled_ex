defmodule SpecLedEx.DocsIdentifierLintTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Corpus-scoped lint over the agent-facing docs and skills. Guards two defect
  classes that a reviewer would otherwise have to catch by hand:

    1. Fabricated finding codes — a `append_only/*`, `overlap/*`, or
       `branch_guard_*` token in the prose that no detector actually emits.
    2. Inert config severities — the `:atom` value form inside a YAML block,
       which `SpecLedEx.Config` silently drops (a bare `off`/`info`/`warning`/
       `error` token is required).

  The known-code allowlist below mirrors the implementation. It is a vetted,
  hand-maintained set rather than reflection because its job is to fail loudly:
  a genuinely new code lands here in the same change that starts documenting it,
  and a typo'd or removed code trips the test until the docs are corrected.
  """

  # append_only/* → SpecLedEx.AppendOnly (mirrored in branch_check.ex @per_code_defaults)
  @append_only_codes ~w(
    append_only/requirement_deleted
    append_only/must_downgraded
    append_only/scenario_regression
    append_only/negative_removed
    append_only/disabled_without_reason
    append_only/no_baseline
    append_only/adr_affects_widened
    append_only/same_pr_self_authorization
    append_only/missing_change_type
    append_only/decision_deleted
  )

  # overlap/* → SpecLedEx.Overlap
  @overlap_codes ~w(
    overlap/duplicate_covers
    overlap/must_stem_collision
  )

  # branch_guard_* → branch_check.ex @per_code_defaults + coverage_triangulation.ex tiers
  @branch_guard_codes ~w(
    branch_guard_unmapped_change
    branch_guard_missing_subject_update
    branch_guard_missing_decision_update
    branch_guard_requirement_without_test_tag
    branch_guard_realization_drift
    branch_guard_dangling_binding
    branch_guard_realization_unknown_tier
    branch_guard_untested_realization
    branch_guard_untethered_test
    branch_guard_underspecified_realization
  )

  @known_codes MapSet.new(@append_only_codes ++ @overlap_codes ++ @branch_guard_codes)

  @token_patterns [
    ~r{append_only/[a-z_]+},
    ~r{overlap/[a-z_]+},
    ~r{branch_guard_[a-z_]+}
  ]

  # Elixir-atom severity value inside a YAML mapping, e.g. `code: :off`.
  @atom_severity_pattern ~r/:\s+:(off|info|warning|error)\b/

  defp corpus_files do
    (Path.wildcard("skills/**/*.md") ++ Path.wildcard("docs/*.md") ++ ["README.md"])
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "every finding-code-shaped token in docs references a real implementation code" do
    unknown =
      for file <- corpus_files(),
          {line, lineno} <- Enum.with_index(File.stream!(file), 1),
          pattern <- @token_patterns,
          token <- @known_codes |> unknown_tokens(pattern, line) do
        "#{file}:#{lineno}: unknown finding code #{inspect(token)}"
      end

    assert unknown == [],
           "Docs reference finding codes with no implementation counterpart:\n" <>
             Enum.join(unknown, "\n")
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "YAML blocks in docs use bare severity tokens, not the inert :atom form" do
    offenders =
      for file <- corpus_files(),
          {lineno, line} <- yaml_block_lines(File.read!(file)),
          Regex.match?(@atom_severity_pattern, line) do
        "#{file}:#{lineno}: atom-form severity #{inspect(String.trim(line))}" <>
          " — use a bare token (off/info/warning/error)"
      end

    assert offenders == [],
           "Config severities in YAML blocks must be bare tokens, not Elixir atoms:\n" <>
             Enum.join(offenders, "\n")
  end

  defp unknown_tokens(known, pattern, line) do
    pattern
    |> Regex.scan(line)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
  end

  # Returns {lineno, line} tuples for every source line that sits inside a
  # ```yaml fenced block (info-strings like `yaml spec-meta` still count).
  defp yaml_block_lines(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, lineno}, {lang, acc} ->
      cond do
        fence?(line) and is_nil(lang) -> {fence_lang(line), acc}
        fence?(line) -> {nil, acc}
        lang == "yaml" -> {lang, [{lineno, line} | acc]}
        true -> {lang, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp fence?(line), do: Regex.match?(~r/^\s*```/, line)

  defp fence_lang(line) do
    line
    |> String.trim()
    |> String.trim_leading("`")
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
  end
end
