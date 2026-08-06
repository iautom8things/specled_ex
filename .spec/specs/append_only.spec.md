# Append-Only

State-based append-only validation for `.spec/` requirements, scenarios, and ADRs
across a Git base..HEAD diff.

## Intent

Enforce that committed spec content cannot be silently weakened or deleted without
an authorizing ADR. The canonical baseline is reconstructed from base-tree
`.spec/specs` and `.spec/decisions` sources with the current parser; detection is
a pure function over two normalized state payloads plus the head-side decision
list. The realization-hash baseline is out of append-only's scope: it lives in
`.spec/realization_hashes.json` (not in state.json), and
`SpecLedEx.write_state/4` hoists a legacy embedded `realization` section into
that file before regenerating state.json.

The code-fenced `fix:` block convention these findings established is shared
by branch-guard governance findings (`branch_guard_missing_decision_update`).

```yaml spec-meta
id: specled.append_only
kind: module
status: active
summary: Diff-time detectors for deleted requirements, modal downgrades, scenario regressions, polarity loss, ADR widening, and ADR deletion, plus supporting bootstrap + advisory findings.
surface:
  - lib/specled_ex/append_only.ex
  - lib/specled_ex.ex
  - test/specled_ex/append_only_test.exs
  - test_support/append_only_fixtures.ex
realized_by:
  api_boundary:
    - "SpecLedEx.AppendOnly.analyze/4"
decisions:
  - specled.decision.adr_append_only
  - specled.decision.modal_class_diff_time
  - specled.decision.change_type_enum_v1
  - specled.decision.finding_code_budget
  - specled.decision.append_only_finding_budget_v2
  - specled.decision.declarative_current_truth
```

## Requirements

```yaml spec-requirements
- id: specled.append_only.requirement_deleted
  statement: >-
    AppendOnly.analyze shall emit `append_only/requirement_deleted` at
    `:error` when a requirement id (or an entire subject and its
    requirements) present in the prior state is absent from the current
    state and no head-side ADR in the weakening set (`deprecates`,
    `weakens`, `narrows-scope`, `adds-exception`) lists the removed id in
    its `affects` list.
  priority: must
  stability: evolving
  realized_by:
    api_boundary:
      - "SpecLedEx.AppendOnly.analyze/4"
- id: specled.append_only.requirement_deleted_authorized
  statement: >-
    AppendOnly.analyze shall NOT emit `append_only/requirement_deleted`
    for a removed requirement id when a head-side ADR in the weakening
    set (`deprecates`, `weakens`, `narrows-scope`, `adds-exception`)
    lists that id in its `affects` list with a non-empty
    `reverses_what`, authorizing the deletion.
  priority: must
  stability: evolving
- id: specled.append_only.must_downgraded
  statement: >-
    AppendOnly.analyze shall emit `append_only/must_downgraded` at `:error`
    when a requirement that existed in the prior state had a stronger
    modal class (MUST or SHALL) and the head-side statement classifies to
    a weaker class (SHOULD, MAY, or NONE) or crosses polarity in a way
    that loses a negative assertion, unauthorized by a weakening-set ADR
    targeting that id.
  priority: must
  stability: evolving
- id: specled.append_only.scenario_regression
  statement: >-
    AppendOnly.analyze shall emit `append_only/scenario_regression` at
    `:error` when the number of scenarios that cover a given requirement
    id decreases from prior to current state without a weakening-set ADR
    authorizing the id.
  priority: must
  stability: evolving
- id: specled.append_only.negative_removed
  statement: >-
    AppendOnly.analyze shall emit `append_only/negative_removed` at
    `:error` when a requirement carried `polarity` of `negative` (explicit
    or auto-inferred from MUST NOT / SHALL NOT) in the prior state and the
    head-side statement no longer carries that polarity, unauthorized by
    a weakening-set ADR targeting the id.
  priority: must
  stability: evolving
- id: specled.append_only.disabled_without_reason
  statement: >-
    AppendOnly.analyze shall emit `append_only/disabled_without_reason`
    at `:warning` for every head-side scenario whose `execute` is set to
    false without a non-empty `reason` field, independent of the prior
    state.
  priority: must
  stability: evolving
- id: specled.append_only.no_baseline
  statement: >-
    AppendOnly.analyze shall emit exactly one `append_only/no_baseline`
    finding at `:info` when prior state is `:missing`, carrying a variant
    tag distinguishing first-run bootstrap from shallow-clone from
    bad-ref conditions, and shall emit no other `append_only/*` findings
    in that invocation.
  priority: must
  stability: evolving
  realized_by:
    api_boundary:
      - "SpecLedEx.AppendOnly.analyze/4"
- id: specled.append_only.adr_affects_widened
  statement: >-
    AppendOnly.analyze shall emit `append_only/adr_affects_widened` at
    `:error` when an ADR present at base with status `accepted` has a
    different `affects` list (or different `change_type`, or different
    `reverses_what`) at head, since accepted ADRs are structurally
    immutable per `specled.decision.adr_append_only`.
  priority: must
  stability: evolving
- id: specled.append_only.same_pr_self_authorization
  statement: >-
    AppendOnly.analyze shall emit `append_only/same_pr_self_authorization`
    at `:warning` for each ADR that is new in the current diff, carries a
    weakening-set `change_type`, and whose non-empty `affects` set consists
    entirely of requirement ids weakened in that same diff — where a
    requirement id is weakened when it is removed, scenario-count-regressed,
    modal-downgraded, or stripped of negative polarity between prior and
    current state — making the self-authorization pattern visible without
    blocking the PR.
  priority: must
  stability: evolving
- id: specled.append_only.self_authorized_weakening
  statement: >-
    AppendOnly.analyze shall emit `append_only/self_authorized_weakening` at
    `:info`, with entity_id the weakened requirement id, whenever a requirement
    deletion, scenario regression, modal downgrade, or polarity removal is
    suppressed as authorized by an ADR that is new in the current diff, naming
    the authorizing ADR id and the weakening class in the message, so
    self-approved weakening is always visible in analyze output. Weakenings
    authorized by ADRs already present at base shall emit no marker.
  priority: must
  stability: evolving
- id: specled.append_only.missing_change_type
  statement: >-
    AppendOnly.analyze shall emit `append_only/missing_change_type` at
    `:warning` when an ADR referenced by an authorization lookup lacks
    the `change_type` field, matching the v1 warning-level optionality of
    `change_type` per `specled.decision.change_type_enum_v1`.
  priority: must
  stability: evolving
- id: specled.append_only.decision_deleted
  statement: >-
    AppendOnly.analyze shall emit `append_only/decision_deleted` at
    `:error` when an ADR id present in the prior state's decisions is
    absent from the current state's decisions, since the only authorized
    removal is a status transition (to `deprecated` or `superseded`) on
    the existing ADR file.
  priority: must
  stability: evolving
- id: specled.append_only.identity
  statement: >-
    AppendOnly.analyze shall return an empty findings list when called
    with identical prior and current states and an empty decisions list
    (no false positives on unchanged trees).
  priority: must
  stability: stable
- id: specled.append_only.findings_sorted
  statement: >-
    AppendOnly.analyze shall return its findings list sorted by subject
    id, then entity id, then code, with nil keys treated as the empty
    string, so downstream consumers and snapshot tests see a stable
    order.
  priority: must
  stability: stable
- id: specled.append_only.fix_block_discipline
  statement: >-
    Every `append_only/*` finding message shall end with a code-fenced
    `fix:` block naming either the required ADR `change_type` (for
    weakening violations) or the restore action (for deletions), so the
    R1.f remediation contract is satisfiable from the message alone.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.append_only.scenario.unauthorized_requirement_delete
  given:
    - "prior state contains requirement `x.req_a` in subject `x`"
    - "current state does not contain `x.req_a`"
    - "no head-side ADR with affects `[x.req_a]` and change_type in {deprecates, weakens, narrows-scope, adds-exception} exists"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains one finding with code `append_only/requirement_deleted` at severity error, subject_id x, entity_id x.req_a"
  covers:
    - specled.append_only.requirement_deleted

- id: specled.append_only.scenario.authorized_requirement_delete_passes
  given:
    - "prior state contains requirement `x.req_a`"
    - "current state does not contain `x.req_a`"
    - "a head-side ADR with change_type deprecates, affects `[x.req_a]`, non-empty reverses_what exists"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "no `append_only/requirement_deleted` finding is emitted for `x.req_a`"
  covers:
    - specled.append_only.requirement_deleted_authorized

- id: specled.append_only.scenario.must_to_should_downgrade
  given:
    - "prior state requirement `x.req_a` has statement `The system MUST reject invalid input.`"
    - "current state requirement `x.req_a` has statement `The system SHOULD reject invalid input.`"
    - no weakening-set ADR references `x.req_a`
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains one finding with code `append_only/must_downgraded` at severity error, entity_id x.req_a"
  covers:
    - specled.append_only.must_downgraded

- id: specled.append_only.scenario.scenario_count_drops
  given:
    - "prior state has two scenarios covering requirement `x.req_a`"
    - "current state has one scenario covering `x.req_a`"
    - no weakening-set ADR references `x.req_a`
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/scenario_regression` for `x.req_a`"
  covers:
    - specled.append_only.scenario_regression

- id: specled.append_only.scenario.negative_polarity_removed
  given:
    - "prior state requirement `x.req_a` has polarity negative"
    - "current state requirement `x.req_a` has statement without MUST NOT / SHALL NOT and no polarity negative frontmatter"
    - no weakening-set ADR references `x.req_a`
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/negative_removed` for `x.req_a`"
  covers:
    - specled.append_only.negative_removed

- id: specled.append_only.scenario.disabled_scenario_needs_reason
  given:
    - "current state contains a scenario with execute false and no reason field"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/disabled_without_reason` at warning pointing at that scenario id"
  covers:
    - specled.append_only.disabled_without_reason

- id: specled.append_only.scenario.missing_baseline_bootstrap
  given:
    - "prior state is missing (first-run or shallow-clone classifier outcome)"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked with a populated current state
  then:
    - "the returned findings list contains exactly one finding with code `append_only/no_baseline` at severity info"
    - "no other `append_only/*` findings are emitted"
  covers:
    - specled.append_only.no_baseline

- id: specled.append_only.scenario.adr_affects_widened
  given:
    - "prior state decisions includes d1 with status accepted, affects `[x.req_a]`, change_type weakens"
    - "current state decisions includes d1 with affects `[x.req_a, x.req_b]`"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/adr_affects_widened` at error naming d1"
  covers:
    - specled.append_only.adr_affects_widened

- id: specled.append_only.scenario.same_pr_self_authorization_warning
  given:
    - "prior state contains requirement `x.req_a`"
    - "current state does not contain `x.req_a`"
    - "a head-side ADR new in this diff with change_type deprecates, affects `[x.req_a]` exists"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/same_pr_self_authorization` at warning"
    - "no `append_only/requirement_deleted` finding is emitted for `x.req_a`"
  covers:
    - specled.append_only.same_pr_self_authorization

- id: specled.append_only.scenario.same_pr_scenario_regression_self_auth
  given:
    - "prior and current state contain requirement `x.req_a`, with its single covering scenario removed (coverage dropping from one scenario to zero) while the requirement itself survives"
    - "zero requirement ids are deleted"
    - "a head-side ADR new in this diff has a weakening-set change_type and affects `[x.req_a]`"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the scenario regression error is suppressed"
    - "the returned findings contain `append_only/same_pr_self_authorization` at warning with entity_id equal to the ADR id"
  covers: []

- id: specled.append_only.scenario.same_pr_modal_downgrade_self_auth
  given:
    - "requirement `x.req_a` changes from MUST at base to SHOULD at head"
    - "a head-side ADR new in this diff has a weakening-set change_type and affects `[x.req_a]`"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the modal downgrade error is suppressed"
    - "the returned findings contain `append_only/same_pr_self_authorization` at warning with entity_id equal to the ADR id"
  covers: []

- id: specled.append_only.scenario.same_pr_polarity_removal_self_auth
  given:
    - "requirement `x.req_a` loses negative polarity between base and head"
    - "zero requirement ids are deleted"
    - "a head-side ADR new in this diff has a weakening-set change_type and affects `[x.req_a]`"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the negative-polarity removal error is suppressed"
    - "the returned findings contain `append_only/same_pr_self_authorization` at warning with entity_id equal to the ADR id"
  covers: []

- id: specled.append_only.scenario.self_authorized_weakening_marker
  given:
    - "a scenario regression for requirement `x.req_a` is authorized by ADR d1"
    - "ADR d1 is new in the current diff"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the suppressed regression emits `append_only/self_authorized_weakening` at info with entity_id x.req_a"
    - "the marker message names ADR d1 and the scenario-regression weakening class"
  covers:
    - specled.append_only.self_authorized_weakening

- id: specled.append_only.scenario.superset_affects_deletion_marker_without_warning
  given:
    - "requirement `x.req_a` is deleted"
    - "a new head-side ADR affects `[x.req_a, x.req_b]`, where x.req_b is not weakened in the diff"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the deletion error is suppressed and an `append_only/self_authorized_weakening` info marker is emitted for x.req_a"
    - "no `append_only/same_pr_self_authorization` warning is emitted because the ADR affects set is not a subset of weakened ids"
  covers: []

- id: specled.append_only.scenario.preexisting_adr_emits_no_self_auth_findings
  given:
    - "a weakening of requirement `x.req_a` is authorized by an ADR present in both base and head"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the weakening error is suppressed"
    - "neither `append_only/same_pr_self_authorization` nor `append_only/self_authorized_weakening` is emitted"
  covers: []

- id: specled.append_only.scenario.missing_change_type_warns
  given:
    - "a head-side ADR d2 referenced during an authorization lookup lacks a change_type field"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/missing_change_type` at warning naming d2"
  covers:
    - specled.append_only.missing_change_type

- id: specled.append_only.scenario.decision_file_deleted
  given:
    - "prior state decisions includes d3"
    - "current state decisions does not include d3"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list contains `append_only/decision_deleted` at error naming d3"
  covers:
    - specled.append_only.decision_deleted

- id: specled.append_only.scenario.identity_returns_empty
  given:
    - a populated state s and an empty decisions list
  when:
    - "SpecLedEx.AppendOnly.analyze/4 is invoked with prior s, current s, decisions []"
  then:
    - the returned findings list is empty
  covers:
    - specled.append_only.identity

- id: specled.append_only.scenario.output_sorted
  given:
    - a diff that would produce three findings across two subjects
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "the returned findings list is sorted by subject_id then entity_id then code, with nil keys treated as empty string"
  covers:
    - specled.append_only.findings_sorted

- id: specled.append_only.scenario.fix_block_present
  given:
    - "any diff that produces at least one `append_only/*` finding"
  when:
    - SpecLedEx.AppendOnly.analyze/4 is invoked
  then:
    - "every `append_only/*` message ends with a code-fenced `fix:` block"
  covers:
    - specled.append_only.fix_block_discipline
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.append_only.requirement_deleted
    - specled.append_only.requirement_deleted_authorized
    - specled.append_only.must_downgraded
    - specled.append_only.scenario_regression
    - specled.append_only.negative_removed
    - specled.append_only.disabled_without_reason
    - specled.append_only.no_baseline
    - specled.append_only.adr_affects_widened
    - specled.append_only.same_pr_self_authorization
    - specled.append_only.self_authorized_weakening
    - specled.append_only.missing_change_type
    - specled.append_only.decision_deleted
    - specled.append_only.identity
    - specled.append_only.findings_sorted
    - specled.append_only.fix_block_discipline
- kind: source_file
  target: lib/specled_ex/append_only.ex
  execute: true
  covers:
    - specled.append_only.requirement_deleted
    - specled.append_only.requirement_deleted_authorized
    - specled.append_only.must_downgraded
    - specled.append_only.scenario_regression
    - specled.append_only.negative_removed
    - specled.append_only.disabled_without_reason
    - specled.append_only.no_baseline
    - specled.append_only.adr_affects_widened
    - specled.append_only.same_pr_self_authorization
    - specled.append_only.self_authorized_weakening
    - specled.append_only.missing_change_type
    - specled.append_only.decision_deleted
```

## Known v1 limits

- **Narrowing-via-split (C6).** Splitting one broad scenario into two narrow ones keeps
  `scenario_regression`'s count-based check stable. Content-similarity is explicitly not
  in scope for v1.
- **Same-PR self-authorization (C3).** A single PR can author both any of the four
  weakening classes and the authorizing ADR; the `same_pr_self_authorization` warning
  and per-requirement marker surface the pattern without blocking. Review still decides
  whether the self-authorization is legitimate.
- **Concurrent PR race (C12).** Two PRs branched from the same base can each pass
  AppendOnly individually but combine into an invalid state on main. Standard GH merge-queue
  rerun closes this outside specled_ex.
- **Cross-polarity modal transitions.** `must` ↔ `must_not` transitions are conservatively
  treated as weakening to avoid silent strength loss; authors can always attach a weakening-set
  ADR.
