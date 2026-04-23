# Modal Class

Pure classifier for the normative strength of a requirement statement
(MUST / SHALL / MUST NOT / SHALL NOT / SHOULD / MAY / NONE), plus a total
order over modal pairs used by AppendOnly to detect downgrades.

## Intent

Give AppendOnly a deterministic way to decide whether a head-side statement
is weaker than the prior-state statement for the same requirement id. The
classifier runs at diff time, not at spec-validate time; modal class is never
cached on the requirement struct and never serialized into `state.json`.

```yaml spec-meta
id: specled.modal_class
kind: module
status: draft
summary: Pure classify/1 over requirement statements plus total downgrade?/2 over the modal × modal Cartesian product, consumed by AppendOnly's detect_must_downgrade/3.
surface:
  - lib/specled_ex/modal_class.ex
  - test/specled_ex/modal_class_test.exs
decisions:
  - specled.decision.modal_class_diff_time
  - specled.decision.finding_code_budget
```

## Requirements

```yaml spec-requirements
- id: specled.modal_class.classify_total
  statement: >-
    ModalClass.classify/1 shall return one of the atoms `:must`,
    `:shall`, `:must_not`, `:shall_not`, `:should`, `:may`, or `:none`
    for any binary-string input, never raising and never returning nil.
  priority: must
  stability: stable
- id: specled.modal_class.classify_deterministic
  statement: >-
    ModalClass.classify/1 shall be deterministic: identical input strings
    shall return the same atom across invocations, compile units, and
    test runs.
  priority: must
  stability: stable
- id: specled.modal_class.classify_case_and_punctuation_insensitive
  statement: >-
    ModalClass.classify/1 shall classify identically across case
    variations (lowercase, uppercase, mixed) and trailing punctuation, so
    that `the system must reject X.` and `The system MUST reject X` both
    classify to `:must`.
  priority: must
  stability: evolving
- id: specled.modal_class.downgrade_total
  statement: >-
    ModalClass.downgrade?/2 shall be total over the full modal × modal
    Cartesian product (49 pairs) and shall return a boolean without
    raising.
  priority: must
  stability: stable
- id: specled.modal_class.downgrade_monotonic
  statement: >-
    ModalClass.downgrade?/2 shall be monotonic on the partial order over
    modals such that if downgrade? from a to b is true and downgrade?
    from b to c is true, then downgrade? from a to c is true.
  priority: must
  stability: stable
- id: specled.modal_class.cross_polarity_conservative
  statement: >-
    ModalClass.downgrade?/2 shall classify `:must` to `:must_not` (and
    `:shall` to `:shall_not`) as downgrade true and `:must_not` to
    `:must` (and `:shall_not` to `:shall`) as downgrade false, and any
    ambiguous cross-polarity transition that loses a negative assertion
    shall be classified as a downgrade to stay conservative.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.modal_class.scenario.must_classification
  given:
    - "the input string `The system MUST reject invalid input.`"
  when:
    - SpecLedEx.ModalClass.classify/1 is invoked
  then:
    - "the return value is `:must`"
  covers:
    - specled.modal_class.classify_total

- id: specled.modal_class.scenario.should_classification
  given:
    - "the input string `The system should log a warning.`"
  when:
    - SpecLedEx.ModalClass.classify/1 is invoked
  then:
    - "the return value is `:should`"
  covers:
    - specled.modal_class.classify_total
    - specled.modal_class.classify_case_and_punctuation_insensitive

- id: specled.modal_class.scenario.none_classification
  given:
    - "the input string `The system logs a warning.` (no modal verb)"
  when:
    - SpecLedEx.ModalClass.classify/1 is invoked
  then:
    - "the return value is `:none`"
  covers:
    - specled.modal_class.classify_total

- id: specled.modal_class.scenario.deterministic
  given:
    - a statement string s
  when:
    - SpecLedEx.ModalClass.classify/1 is invoked twice with s
  then:
    - the two return values are equal
  covers:
    - specled.modal_class.classify_deterministic

- id: specled.modal_class.scenario.must_to_should_is_downgrade
  given:
    - "modals `:must` and `:should`"
  when:
    - "SpecLedEx.ModalClass.downgrade?/2 is invoked as downgrade?(:must, :should)"
  then:
    - the return value is true
  covers:
    - specled.modal_class.downgrade_total

- id: specled.modal_class.scenario.should_to_must_is_not_downgrade
  given:
    - "modals `:should` and `:must`"
  when:
    - "SpecLedEx.ModalClass.downgrade?/2 is invoked as downgrade?(:should, :must)"
  then:
    - the return value is false
  covers:
    - specled.modal_class.downgrade_total

- id: specled.modal_class.scenario.must_to_must_not_is_downgrade
  given:
    - "modals `:must` and `:must_not`"
  when:
    - "SpecLedEx.ModalClass.downgrade?/2 is invoked as downgrade?(:must, :must_not)"
  then:
    - the return value is true
  covers:
    - specled.modal_class.cross_polarity_conservative

- id: specled.modal_class.scenario.must_not_to_must_is_not_downgrade
  given:
    - "modals `:must_not` and `:must`"
  when:
    - "SpecLedEx.ModalClass.downgrade?/2 is invoked as downgrade?(:must_not, :must)"
  then:
    - the return value is false
  covers:
    - specled.modal_class.cross_polarity_conservative

- id: specled.modal_class.scenario.transitivity
  given:
    - three modals a, b, c where downgrade? from a to b and downgrade? from b to c both hold
  when:
    - "SpecLedEx.ModalClass.downgrade?/2 is invoked as downgrade?(a, c)"
  then:
    - the return value is true
  covers:
    - specled.modal_class.downgrade_monotonic
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/modal_class_test.exs
  execute: false
  covers:
    - specled.modal_class.classify_total
    - specled.modal_class.classify_deterministic
    - specled.modal_class.classify_case_and_punctuation_insensitive
    - specled.modal_class.downgrade_total
    - specled.modal_class.downgrade_monotonic
    - specled.modal_class.cross_polarity_conservative
- kind: source_file
  target: lib/specled_ex/modal_class.ex
  execute: false
  covers:
    - specled.modal_class.classify_total
    - specled.modal_class.downgrade_total
```
