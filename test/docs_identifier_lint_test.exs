defmodule SpecLedEx.DocsIdentifierLintTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Corpus-scoped lint over the agent-facing docs, skills, and repo-resident
  spec workspace. Guards two defect classes that a reviewer would otherwise
  have to catch by hand:

    1. Fabricated finding codes — an `append_only/*`, `overlap/*`,
       `evidence/*`, `cross_field/*`, or `branch_guard_*` token that no
       detector actually emits. Checked across the guidance docs/skills AND the
       `.spec/**` workspace (subject specs and decision records), because a
       fabricated code that survives in a spec scenario or an ADR is just as
       misleading as one in a skill.

       Those five are every emitted family carrying a namespace or a shared
       prefix. The rest of the emitted codes — `detector_unavailable`,
       `spec_requirement_too_short`, and the several dozen bare validator and
       tag-scanner codes — are plain snake_case, and the stem patterns that
       would catch them collide with the corpus itself. Measured against the
       current corpus: `detector_` hits the review-output field
       `detector_unavailable_by_leg` and the requirement id
       `specled.triangulation.detector_unavailable_on_missing_coverage`;
       `decision_` hits nine non-codes including `decision_dir` and
       `decision_governance`; `verification_` and `requirement_` hit four and
       six. Each would reject correct prose, so those codes stay
       author-enforced and the `must` says so.

       The nine includes bare `decision_deleted`, which reads like a code but
       is not one: the emitted code is `append_only/decision_deleted`, and the
       namespaced form is what the lint already guards. A `decision_[a-z_]+`
       pattern would flag the bare spelling as fabricated, so it counts as a
       false positive.

       That reasoning covers only the four stems named above. They match many
       of the unguarded codes but by no means all — many others are matched by
       none of the four — and at least five narrower stems (`surface_target_`,
       `scenario_cover_`, `meta_field_`, `spec_requirement_`, `invalid_id_`)
       collide with nothing in the corpus today. (No totals: the emitted-code
       denominator shifts with whether `check/5` outputs and `Mix.raise`
       prefixes count, so the comparison is stated and the total is not.) Those are guardable, and unguarded for a different
       reason: each needs its own hand-maintained allowlist, since
       `specled.decision.doc_identifier_lint_spec_corpus` rejects deriving the
       code set by reflection over lib/. Deferred, not impossible — the
       `must` keeps the two reasons apart on purpose.

       Note the trap in conflating them: `spec_requirement_too_short` is one of
       the exemplars named in the `must`, and NONE of the four large stems
       matches it (`(?<![\w/])requirement_` cannot match mid-token, since the
       preceding `_` is a word character). Its own stem `spec_requirement_` has
       zero corpus collisions. A sentence claiming the four stems explain why
       every bare code is author-enforced supplies its own counterexample.
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

  # evidence/* → the evidence store, its sync/prune reconciliation, and the
  # `mix spec.sync` / `mix spec.prune` task surface. The first four are warning
  # findings carried on a `%{code:, message:}` map; the last three are the
  # `Mix.raise` message prefixes those tasks abort with. Both forms are codes a
  # doc can legitimately name, and both are equally wrong when misspelled.
  @evidence_codes ~w(
    evidence/auto_prune_degraded
    evidence/entry_quarantined
    evidence/entry_skipped
    evidence/local_write_failed
    evidence/prune_failed
    evidence/prune_refused
    evidence/sync_failed
  )

  # cross_field/* → SpecLedEx.DecisionParser.CrossField. Note that
  # `cross_field/missing_change_type` and `append_only/missing_change_type` are
  # distinct codes from distinct detectors; the namespace is what tells them
  # apart, which is precisely why the lint matches on the full token.
  @cross_field_codes ~w(
    cross_field/adr_field_drift
    cross_field/adr_status_regression
    cross_field/affects_empty
    cross_field/affects_unresolved
    cross_field/missing_change_type
    cross_field/reverses_what_missing
    cross_field/supersedes_missing_replaces
    cross_field/supersedes_unresolved_replaces
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

  @known_codes MapSet.new(
                 @append_only_codes ++
                   @overlap_codes ++
                   @evidence_codes ++ @cross_field_codes ++ @branch_guard_codes
               )

  # The leading `(?<![\w/])` negative lookbehind keeps the token from matching
  # inside a file path or a longer identifier — e.g. the `branch_guard_test`
  # substring of a `.../config/branch_guard_test.exs` closure-file reference in a
  # spec is a path segment, not a finding code.
  @token_patterns [
    ~r{(?<![\w/])append_only/[a-z_]+},
    ~r{(?<![\w/])overlap/[a-z_]+},
    # `evidence` is unlike the other four families in that it is also a real
    # directory name (`lib/specled_ex/evidence/`). Slash-prefixed path mentions
    # are already skipped by the lookbehind, but a bare relative path written
    # after a space — "see evidence/sync.ex" — would match and be reported as a
    # fabricated code. No such reference exists today; the residual risk remains
    # if a bare relative path of that form is ever introduced in the corpus.
    ~r{(?<![\w/])evidence/[a-z_]+},
    ~r{(?<![\w/])cross_field/[a-z_]+},
    ~r{(?<![\w/])branch_guard_[a-z_]+}
  ]

  # Per-token allow-marker: `<!-- spec-lint:allow-code=<token> reason -->`.
  # Requires the HTML-comment wrapper — bare `spec-lint:allow-code=...` prose
  # is not a marker and grants no exemption (and is invisible to the
  # staleness sweep for the same reason). Exempts only the exact token it
  # names, on the line it appears on. Reason text may contain `>`; matching
  # is non-greedy to `-->` and stays single-line-scoped (no `s` modifier —
  # the corpus is streamed line-by-line via File.stream!/1). One grammar
  # serves both exemption (`allowed_codes/1`) and strip
  # (`stale_allow_marker_violations_for_line/3`); a second approximate copy
  # could only drift from the real one.
  @allow_marker_pattern ~r{<!--\s*spec-lint:allow-code=([a-z_/]+)\b.*?-->}

  # ...and the marker is honoured ONLY in decision records. Guidance docs, skill
  # files, README, and subject specs get no escape hatch: those surfaces had none
  # before this check existed, and granting one there would let "make the lint
  # green" mean "mark the code" instead of "correct it". This mirrors the `must`
  # and `specled.decision.doc_identifier_lint_spec_corpus`, which both scope the
  # marker to decision records.
  @marker_scope ".spec/decisions/"

  # Elixir-atom severity value inside a YAML mapping, e.g. `code: :off`.
  @atom_severity_pattern ~r/:\s+:(off|info|warning|error)\b/

  @guarded_code_shape ~r{\A(?:append_only/[a-z0-9_]+|overlap/[a-z0-9_]+|evidence/[a-z0-9_]+|cross_field/[a-z0-9_]+|branch_guard_[a-z0-9_]+)\z}
  @digit_bearing_code ~r/\d/

  @implementation_code_files ~w(
    lib/specled_ex/append_only.ex
    lib/specled_ex/branch_check.ex
    lib/specled_ex/coverage_triangulation.ex
    lib/specled_ex/decision_parser/cross_field.ex
    lib/specled_ex/evidence/store.ex
    lib/specled_ex/evidence/sync.ex
    lib/specled_ex/overlap.ex
    lib/mix/tasks/spec.check.ex
    lib/mix/tasks/spec.prune.ex
    lib/mix/tasks/spec.sync.ex
  )

  @implementation_code_patterns [
    ~r{"((?:append_only/[a-z0-9_]+|overlap/[a-z0-9_]+|evidence/[a-z0-9_]+|cross_field/[a-z0-9_]+|branch_guard_[a-z0-9_]+))(?:"|:)}
  ]

  # Finding-code integrity is checked across guidance docs/skills AND the
  # repo-resident spec workspace.
  defp finding_code_corpus do
    normalize(guidance_files() ++ Path.wildcard(".spec/**/*.md"))
  end

  defp decision_files do
    normalize(Path.wildcard(".spec/decisions/**/*.md"))
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
    files = finding_code_corpus()

    # `unknown == []` reads identically whether hundreds of tokens were inspected
    # or the glob returned nothing, so pin the corpus size too: a `.spec/` reorg
    # or a cwd change would otherwise turn this whole lint into a silent no-op.
    assert length(files) > 50,
           "finding-code corpus collapsed to #{length(files)} files — the lint is a no-op"

    unknown =
      for file <- files,
          {line, lineno} <- Enum.with_index(File.stream!(file), 1),
          token <- unknown_tokens(line, file) do
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
    files = severity_corpus()

    assert length(files) > 8,
           "severity corpus collapsed to #{length(files)} files — this check is a no-op"

    offenders = atom_severity_offenders(files)

    assert offenders == [],
           "Config severities in YAML blocks must be bare tokens, not Elixir atoms:\n" <>
             Enum.join(offenders, "\n")
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "severity lint scans guidance docs but excludes spec fixtures" do
    assert Enum.any?(finding_code_corpus(), &String.starts_with?(&1, ".spec/"))
    refute Enum.any?(severity_corpus(), &String.starts_with?(&1, ".spec/"))

    # Any-of the live subject specs: several carry atom-form severity inside a
    # YAML block as the input under test. Pinning one path (e.g. prose_guard)
    # broke on a reword of that scenario's `given:`; the any-of survives as
    # long as the shape remains somewhere under .spec/specs/.
    assert atom_severity_offenders(Path.wildcard(".spec/specs/*.spec.md")) != []

    assert atom_severity_offenders([
             fixture_file("""
             ```yaml
             branch_guard:
               severities:
                 branch_guard_realization_drift: :warning
             ```
             """)
           ]) != []
  end

  # The corpus scans above only prove the corpus is clean TODAY — they never feed
  # the rejection path a controlled input, so they cannot defend the allow-marker's
  # contract. These do. Each states the regression it catches.

  # Both paths are arguments to `unknown_tokens/2`, which passes them only to
  # `marker_scoped?/1` and never opens them — they select which side of the
  # marker-scope boundary a line is judged on, nothing more. @decision_file is
  # deliberately a name no file carries, so it cannot start meaning something
  # else if a real ADR is added or renamed.
  @decision_file ".spec/decisions/specled.decision.example.md"
  @guidance_file "docs/concepts.md"

  @tag spec: "specled.package.doc_identifier_integrity"
  test "a real implementation code is never flagged" do
    # Baseline: a known code passes. (This cannot by itself prove the check is
    # non-vacuous — an `== []` assertion holds for a function that always returns
    # []. The next test is the actual non-vacuousness proof.)
    assert unknown_tokens("see `branch_guard_realization_drift` for details", @decision_file) ==
             []
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "a fabricated, unmarked finding code IS flagged" do
    # Catches: the lint silently stops rejecting unknown codes at all.
    assert unknown_tokens("see `branch_guard_totally_made_up` for details", @decision_file) ==
             ["branch_guard_totally_made_up"]
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "the guarded-family count is exactly the number the must claims" do
    # specled.package.doc_identifier_integrity says "the five code families
    # guarded today" and names them. Adding a sixth pattern here without
    # updating the must would turn an accurate statement into an undercount,
    # and no other test in this file would notice — none of them counts
    # families.
    #
    # This is a speed bump, not a guarantee: it pins the lint's count but never
    # reads package.spec.md, so a coordinated edit that adds a pattern AND
    # bumps this to 6 while forgetting the must still passes. It forces a
    # deliberate stop at the right moment, which is the most a test on this
    # side of the boundary can do.
    assert length(@token_patterns) == 5
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "the evidence/* and cross_field/* families are guarded in both directions" do
    # These two families joined the guarded set later than the other three. The
    # live corpus exercises them unevenly — eight evidence references across
    # four distinct codes, but only one cross_field reference — and it can only
    # ever prove the @known_codes half, never the @token_patterns half: a family
    # missing from @token_patterns is simply never scanned, so the corpus stays
    # green while nothing is checked. These controlled inputs cover both halves.
    # A family needs both before it is genuinely guarded.
    #
    # Asserted with flat_map rather than a loop so one run reports every broken
    # family at once; a per-family loop stops at the first failure.
    reals = ~w(evidence/entry_quarantined cross_field/affects_unresolved)
    assert Enum.flat_map(reals, &unknown_tokens("`#{&1}` fires here", @decision_file)) == []

    fakes = ~w(evidence/totally_made_up cross_field/totally_made_up)

    assert Enum.flat_map(fakes, &unknown_tokens("see `#{&1}` for details", @decision_file)) ==
             fakes
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "path-like guarded tokens stay suppressed while a code on the same line is caught" do
    line =
      "closure file .../config/branch_guard_test.exs still names " <>
        "`branch_guard_totally_made_up` as a code"

    assert unknown_tokens(line, @decision_file) == ["branch_guard_totally_made_up"]
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "the hand-maintained known-code mirror matches implementation anchors both ways" do
    implementation_codes = implementation_guarded_codes()

    assert implementation_codes == @known_codes,
           "guarded finding-code mirror drifted\n" <>
             "missing from @known_codes: #{inspect(MapSet.difference(implementation_codes, @known_codes) |> Enum.sort())}\n" <>
             "present in @known_codes but not extracted from @implementation_code_files " <>
             "(#{inspect(@implementation_code_files)}): " <>
             "#{inspect(MapSet.difference(@known_codes, implementation_codes) |> Enum.sort())} " <>
             "— likelier cause is a stale @implementation_code_files list missing a new " <>
             "lib file that emits the code, not a dead entry to delete"
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "guarded implementation codes do not contain digits" do
    digit_codes =
      implementation_guarded_codes()
      |> Enum.filter(&Regex.match?(@digit_bearing_code, &1))
      |> Enum.sort()

    assert digit_codes == [],
           "digit-bearing guarded finding codes require a deliberate lint grammar decision: " <>
             inspect(digit_codes)
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker exempts the exact token it names, in a decision record" do
    # Catches: the marker stops working, so legitimately-budgeted codes in
    # decision records start failing the suite.
    line =
      "a `branch_guard_totally_made_up` code " <>
        "<!-- spec-lint:allow-code=branch_guard_totally_made_up budgeted, never emitted -->"

    assert unknown_tokens(line, @decision_file) == []
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker does NOT exempt outside decision records" do
    # The marker is an escape hatch for ADRs that must name budgeted/rejected
    # codes — NOT for guidance docs, skills, README, or subject specs, none of
    # which had any escape hatch before this lint existed. Catches: honouring the
    # marker corpus-wide, which would let a doc_identifier_integrity failure be
    # taken green by MARKING a fabricated code instead of correcting it.
    line =
      "a `branch_guard_totally_made_up` code " <>
        "<!-- spec-lint:allow-code=branch_guard_totally_made_up not honoured here -->"

    assert unknown_tokens(line, @guidance_file) == ["branch_guard_totally_made_up"]

    assert unknown_tokens(line, ".spec/specs/package.spec.md") ==
             ["branch_guard_totally_made_up"]
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker does NOT rescue a different unmarked code on the same line" do
    # THE safety property: per-token, not per-line. Catches a refactor of
    # allowed_codes/1 or unknown_tokens/1 that exempts the whole line whenever any
    # marker is present — which would let a genuine typo hide behind an unrelated
    # marker. Without this test that regression is invisible: the live corpus has
    # no line carrying a marker for one code and an unmarked fabricated other.
    # The marked side uses a slash-shaped token so the marker grammar's `/` branch
    # is exercised too (all live markers happen to be `branch_guard_*`).
    line =
      "`overlap/marked_one` and `branch_guard_unmarked_two` " <>
        "<!-- spec-lint:allow-code=overlap/marked_one budgeted -->"

    assert unknown_tokens(line, @decision_file) == ["branch_guard_unmarked_two"]
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "decision-record allow-markers remain necessary and never hide real codes" do
    files = decision_files()

    # Siblings at the finding-code and severity corpus tests pin size so a
    # reorg or cwd change cannot silently no-op the lint. N=30 is conservative
    # against the live `.spec/decisions/` tree (~51 files today).
    assert length(files) > 30,
           "decision corpus collapsed to #{length(files)} files — the sweep is a no-op"

    assert Enum.all?(files, &String.starts_with?(&1, ".spec/decisions/")),
           "decision_files/0 returned a path outside .spec/decisions/"

    violations = stale_allow_marker_violations(files)

    assert violations == [],
           "Stale or unnecessary spec-lint allow-markers found:\n" <>
             Enum.join(violations, "\n")
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker for a real implementation code is stale" do
    line =
      "`branch_guard_realization_drift` " <>
        "<!-- spec-lint:allow-code=branch_guard_realization_drift obsolete -->"

    assert stale_allow_marker_violations([{line, @decision_file, 1}]) == [
             ~s|#{@decision_file}:1: allow-marker names real implementation code "branch_guard_realization_drift" — remove the marker|
           ]
  end

  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker must name a token outside the marker on the same line" do
    line = "<!-- spec-lint:allow-code=branch_guard_totally_made_up stale -->"

    assert stale_allow_marker_violations([{line, @decision_file, 1}]) == [
             ~s|#{@decision_file}:1: allow-marker names "branch_guard_totally_made_up" but that token does not appear outside the marker on the same line|
           ]
  end

  # Item 5 (specled_-ozm): a marker naming a non-guarded bare code must not
  # fall through to the false "does not appear outside the marker" claim —
  # `guarded_tokens/1` can never yield such a token. Would fail if the
  # non-guarded-family branch is deleted and the outside-marker arm reclaims it.
  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker naming a non-guarded code is reported as unnecessary" do
    line =
      "`detector_unavailable` <!-- spec-lint:allow-code=detector_unavailable budgeted -->"

    assert stale_allow_marker_violations([{line, @decision_file, 1}]) == [
             ~s|#{@decision_file}:1: allow-marker names "detector_unavailable", which is not in a guarded family — the marker is unnecessary|
           ]
  end

  # Hole 1 regression (specled_-ozm): a `>` in the reason text used to
  # terminate `@allow_marker_comment_pattern`'s `[^>]*` early, so the marker
  # was never stripped and rot direction (b) could not fire. Would fail if
  # the strip grammar reverts to `[^>]*` (or any first-`>`-terminating class).
  @tag spec: "specled.package.doc_identifier_integrity"
  test "an allow-marker whose reason contains > is still stripped for the stale sweep" do
    line = "<!-- spec-lint:allow-code=branch_guard_totally_made_up see A > B -->"

    assert stale_allow_marker_violations([{line, @decision_file, 1}]) == [
             ~s|#{@decision_file}:1: allow-marker names "branch_guard_totally_made_up" but that token does not appear outside the marker on the same line|
           ]
  end

  # Hole 2 regression (specled_-ozm): bare unwrapped `spec-lint:allow-code=...`
  # used to grant a real exemption via `@allow_marker_pattern` while remaining
  # invisible to the staleness strip (which required the wrapper). Would fail
  # if the exemption grammar again accepts bare unwrapped markers.
  @tag spec: "specled.package.doc_identifier_integrity"
  test "a bare unwrapped allow-marker does not exempt a fabricated code" do
    line =
      "a `branch_guard_totally_made_up` code " <>
        "spec-lint:allow-code=branch_guard_totally_made_up no wrapper"

    assert unknown_tokens(line, @decision_file) == ["branch_guard_totally_made_up"]
  end

  # Finding-code-shaped tokens on `line` that neither the implementation emits
  # (@known_codes) nor an on-line allow-marker exempts.
  defp unknown_tokens(line, file) do
    allowed =
      if marker_scoped?(file) do
        MapSet.union(@known_codes, allowed_codes(line))
      else
        @known_codes
      end

    for token <- guarded_tokens(line),
        not MapSet.member?(allowed, token) do
      token
    end
  end

  defp marker_scoped?(file), do: String.starts_with?(file, @marker_scope)

  defp allowed_codes(line) do
    @allow_marker_pattern
    |> Regex.scan(line)
    |> Enum.map(fn [_full, code] -> code end)
    |> MapSet.new()
  end

  defp stale_allow_marker_violations(files) when is_list(files) do
    files
    |> Enum.flat_map(fn
      {line, file, lineno} ->
        stale_allow_marker_violations_for_line(line, file, lineno)

      file ->
        file
        |> File.stream!()
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, lineno} ->
          stale_allow_marker_violations_for_line(line, file, lineno)
        end)
    end)
  end

  defp stale_allow_marker_violations_for_line(line, file, lineno) do
    tokens_outside_marker =
      line
      |> then(&Regex.replace(@allow_marker_pattern, &1, ""))
      |> guarded_tokens()
      |> MapSet.new()

    line
    |> allowed_codes()
    |> Enum.sort()
    |> Enum.flat_map(fn code ->
      cond do
        MapSet.member?(@known_codes, code) ->
          [
            "#{file}:#{lineno}: allow-marker names real implementation code " <>
              "#{inspect(code)} — remove the marker"
          ]

        not Regex.match?(@guarded_code_shape, code) ->
          [
            "#{file}:#{lineno}: allow-marker names #{inspect(code)}, which is not " <>
              "in a guarded family — the marker is unnecessary"
          ]

        not MapSet.member?(tokens_outside_marker, code) ->
          [
            "#{file}:#{lineno}: allow-marker names #{inspect(code)} but that token " <>
              "does not appear outside the marker on the same line"
          ]

        true ->
          []
      end
    end)
  end

  defp guarded_tokens(line) do
    @token_patterns
    |> Enum.flat_map(fn pattern ->
      pattern
      |> Regex.scan(line)
      |> List.flatten()
    end)
    |> Enum.uniq()
  end

  defp implementation_guarded_codes do
    @implementation_code_files
    |> Enum.flat_map(fn file ->
      source = File.read!(file)

      Enum.flat_map(@implementation_code_patterns, fn pattern ->
        pattern
        |> Regex.scan(source)
        |> Enum.map(fn [_full, code] -> code end)
      end)
    end)
    |> Enum.filter(&Regex.match?(@guarded_code_shape, &1))
    |> MapSet.new()
  end

  defp atom_severity_offenders(files) do
    for file <- files,
        {lineno, line} <- yaml_block_lines(File.read!(file)),
        Regex.match?(@atom_severity_pattern, line) do
      "#{file}:#{lineno}: atom-form severity #{inspect(String.trim(line))}" <>
        " — use a bare token (off/info/warning/error)"
    end
  end

  # Directory name carries `SpecLedEx.TempName.cross_vm_suffix/0` so concurrent
  # VMs cannot share a fixed dir whose on_exit File.rm deletes the other VM's
  # fixture between write and read (see
  # `specled.decision.cross_vm_temp_names_reach`).
  defp fixture_file(content) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "specled_docs_identifier_lint_test_#{SpecLedEx.TempName.cross_vm_suffix()}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "fixture-#{System.unique_integer([:positive])}.md")
    File.write!(path, content)
    # Dir is VM-unique via cross_vm_suffix/0, so rm_rf of the whole dir is safe
    # and required — removing only the file leaks an empty dir per run.
    on_exit(fn -> File.rm_rf!(dir) end)
    path
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
