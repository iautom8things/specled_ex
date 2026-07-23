defmodule SpecLedEx.DocsIdentifierLintTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Corpus-scoped lint over the agent-facing docs, skills, and repo-resident
  spec workspace. Guards two defect classes that a reviewer would otherwise
  have to catch by hand:

    1. Fabricated finding codes — a `append_only/*`, `overlap/*`, or
       `branch_guard_*` token that no detector actually emits. Checked across
       the guidance docs/skills AND the `.spec/**` workspace (subject specs and
       decision records), because a fabricated code that survives in a spec
       scenario or an ADR is just as misleading as one in a skill.
    2. Inert config severities — the `:atom` value form inside a YAML block,
       which `SpecLedEx.Config` silently drops (a bare `off`/`info`/`warning`/
       `error` token is required). Scoped to the user-facing guidance corpus
       (skills/docs/README): `.spec/**` scenarios legitimately quote atom-form
       config as the *input under test*, so they are out of this check's scope.

  The known-code allowlist below mirrors the implementation. It is a vetted,
  hand-maintained set rather than reflection because its job is to fail loudly:
  a genuinely new code lands here in the same change that starts documenting it,
  and a typo'd or removed code trips the test until the docs are corrected.

  Decision records must sometimes name a code that is *not* emitted — a
  budgeted-but-unimplemented code, or a rejected design alternative. Rather than
  exempt `.spec/` wholesale (which would defeat the check), such a reference must
  carry an explicit, per-token allow-marker on the same line:

      <!-- spec-lint:allow-code=<token> reason -->

  The marker exempts only the exact token it names, on that one line, so genuine
  typos and removed codes still trip the lint everywhere else.
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

  # The leading `(?<![\w/])` negative lookbehind keeps the token from matching
  # inside a file path or a longer identifier — e.g. the `branch_guard_test`
  # substring of a `.../config/branch_guard_test.exs` closure-file reference in a
  # spec is a path segment, not a finding code.
  @token_patterns [
    ~r{(?<![\w/])append_only/[a-z_]+},
    ~r{(?<![\w/])overlap/[a-z_]+},
    ~r{(?<![\w/])branch_guard_[a-z_]+}
  ]

  # Per-token allow-marker: `<!-- spec-lint:allow-code=<token> reason -->`.
  # Exempts only the exact token it names, on the line it appears on.
  @allow_marker_pattern ~r{spec-lint:allow-code=([a-z_]+(?:/[a-z_]+)?)}

  # Elixir-atom severity value inside a YAML mapping, e.g. `code: :off`.
  @atom_severity_pattern ~r/:\s+:(off|info|warning|error)\b/

  # Finding-code integrity is checked across guidance docs/skills AND the
  # repo-resident spec workspace.
  defp finding_code_corpus do
    normalize(guidance_files() ++ Path.wildcard(".spec/**/*.md"))
  end

  # The atom-severity check stays on the user-facing guidance corpus; `.spec/**`
  # scenarios legitimately quote atom-form config as the input under test.
  defp severity_corpus, do: normalize(guidance_files())

  defp guidance_files do
    Path.wildcard("skills/**/*.md") ++ Path.wildcard("docs/**/*.md") ++ ["README.md"]
  end

  defp normalize(files) do
    files
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "every finding-code-shaped token in docs and specs references a real implementation code" do
    unknown =
      for file <- finding_code_corpus(),
          {line, lineno} <- Enum.with_index(File.stream!(file), 1),
          token <- unknown_tokens(line) do
        "#{file}:#{lineno}: unknown finding code #{inspect(token)}"
      end

    assert unknown == [],
           "Docs/specs reference finding codes with no implementation counterpart\n" <>
             "(if a decision record legitimately names an unimplemented code, tag the line\n" <>
             " with `<!-- spec-lint:allow-code=<token> reason -->`):\n" <>
             Enum.join(unknown, "\n")
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "YAML blocks in docs use bare severity tokens, not the inert :atom form" do
    offenders =
      for file <- severity_corpus(),
          {lineno, line} <- yaml_block_lines(File.read!(file)),
          Regex.match?(@atom_severity_pattern, line) do
        "#{file}:#{lineno}: atom-form severity #{inspect(String.trim(line))}" <>
          " — use a bare token (off/info/warning/error)"
      end

    assert offenders == [],
           "Config severities in YAML blocks must be bare tokens, not Elixir atoms:\n" <>
             Enum.join(offenders, "\n")
  end

  # Finding-code-shaped tokens on `line` that neither the implementation emits
  # (@known_codes) nor an on-line allow-marker exempts.
  defp unknown_tokens(line) do
    allowed = MapSet.union(@known_codes, allowed_codes(line))

    for pattern <- @token_patterns,
        token <- pattern |> Regex.scan(line) |> List.flatten() |> Enum.uniq(),
        not MapSet.member?(allowed, token) do
      token
    end
  end

  defp allowed_codes(line) do
    @allow_marker_pattern
    |> Regex.scan(line)
    |> Enum.map(fn [_full, code] -> code end)
    |> MapSet.new()
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
