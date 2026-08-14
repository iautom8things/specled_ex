defmodule SpecLedEx.DecisionParser.LiveCrossFieldGateTest do
  use SpecLedEx.FixtureCase

  alias SpecLedEx.Index

  # These tests drive the real gate: `Index.build/2` parses a workspace off
  # disk and the verifier runs over its output. Nothing hand-builds an index,
  # because a hand-built index is exactly what hid the resolution bug this
  # wiring exposed — CrossField read string-keyed maps while the live index
  # carries schema structs.

  defp subject_spec do
    """
    # Alpha

    ```spec-meta
    id: alpha.subject
    kind: module
    status: active
    ```

    ```spec-requirements
    - id: alpha.requirement
      statement: Alpha shall do the alpha thing.
      priority: must
      stability: evolving
    ```

    ```spec-scenarios
    - id: alpha.scenario
      covers:
        - alpha.requirement
      given:
        - alpha given
      when:
        - alpha when
      then:
        - alpha then
    ```

    ```spec-verification
    - kind: source_file
      target: README.md
      execute: true
      covers:
        - alpha.requirement
    ```
    """
  end

  # A workspace whose only findings are the ones under test. Without the
  # verification item the subject trips `requirement_without_verification`,
  # which fails a strict gate for reasons unrelated to cross-field validation.
  defp write_workspace(root) do
    write_spec(root, "alpha", subject_spec())
    write_files(root, %{"README.md" => "# Fixture\n\n<!-- covers: alpha.requirement -->\n"})
  end

  defp adr(id, frontmatter) do
    """
    ---
    id: #{id}
    status: accepted
    date: 2026-08-14
    #{frontmatter}
    ---

    # #{id}

    ## Context

    Why.

    ## Decision

    What.

    ## Consequences

    So what.
    """
  end

  defp decision_by_id(index, id) do
    Enum.find(index["decisions"], fn decision -> decision["meta"]["id"] == id end)
  end

  defp findings_for(root, index) do
    SpecLedEx.validate(index, root, strict: true, run_commands: false)
  end

  @tag spec: "specled.decisions.cross_field_live_gate"
  test "affects that resolve against the built index produce no finding", %{root: root} do
    write_workspace(root)

    write_decision(
      root,
      "resolves",
      adr("adr.resolves", """
      change_type: narrows-scope
      reverses_what: >-
        Alpha used to do the whole thing.
      affects:
        - alpha.subject
        - alpha.requirement
        - alpha.scenario
        - repo.governance
      """)
    )

    write_decision(
      root,
      "deprecates",
      adr("adr.deprecates", """
      change_type: deprecates
      reverses_what: >-
        The retired subject is going away.
      affects:
        - retired.subject
      """)
    )

    index = Index.build(root, test_tags: false)

    assert decision_by_id(index, "adr.resolves")["parse_errors"] == []
    assert decision_by_id(index, "adr.deprecates")["parse_errors"] == []
    assert index["summary"]["decision_parse_errors"] == 0

    report = findings_for(root, index)

    assert report["status"] == "pass"
  end

  # The 0.15.0 escape: three narrows-scope ADRs with no `reverses_what:` shipped
  # and `mix spec.check` returned pass, because nothing on the live path ran R2.
  @tag spec: "specled.decisions.cross_field_reverses_what"
  test "a weakening ADR with no reverses_what fails the gate", %{root: root} do
    write_workspace(root)

    write_decision(
      root,
      "unjustified",
      adr("adr.unjustified", """
      change_type: narrows-scope
      affects:
        - alpha.requirement
      """)
    )

    index = Index.build(root, test_tags: false)

    assert ["cross_field/reverses_what_missing: " <> _] =
             decision_by_id(index, "adr.unjustified")["parse_errors"]

    report = findings_for(root, index)

    assert report["status"] == "fail"

    assert Enum.any?(report["findings"], fn finding ->
             finding["severity"] == "error" and
               finding["code"] == "decision_parse_error" and
               finding["message"] =~ "cross_field/reverses_what_missing"
           end)
  end

  @tag spec: "specled.decisions.cross_field_affects_resolve"
  test "an unresolvable non-deprecates affect fails the gate", %{root: root} do
    write_workspace(root)

    write_decision(
      root,
      "dangling",
      adr("adr.dangling", """
      change_type: narrows-scope
      reverses_what: >-
        Something used to be broader.
      affects:
        - nowhere.subject
      """)
    )

    index = Index.build(root, test_tags: false)

    assert ["cross_field/affects_unresolved: " <> message] =
             decision_by_id(index, "adr.dangling")["parse_errors"]

    assert message =~ "nowhere.subject"

    report = findings_for(root, index)

    assert report["status"] == "fail"
  end

  # `mix spec.check` validates with strict: true, where a warning-severity
  # finding fails the gate exactly like an error. Reporting the missing
  # change_type at warning severity would therefore break every workspace
  # holding a legacy ADR — the outcome change_type_optional exists to prevent.
  @tag spec: "specled.decisions.change_type_optional"
  test "a change_type-less ADR warns without failing a strict gate", %{root: root} do
    write_workspace(root)

    write_decision(
      root,
      "legacy",
      adr("adr.legacy", """
      affects:
        - alpha.requirement
      """)
    )

    index = Index.build(root, test_tags: false)
    decision = decision_by_id(index, "adr.legacy")

    assert decision["parse_errors"] == []
    assert ["cross_field/missing_change_type: " <> _] = decision["parse_warnings"]
    assert index["summary"]["decision_parse_warnings"] == 1

    report = findings_for(root, index)

    assert report["status"] == "pass"

    assert [warning] =
             Enum.filter(report["findings"], &(&1["code"] == "decision_cross_field_warning"))

    assert warning["severity"] == "info"
    assert warning["message"] =~ "cross_field/missing_change_type"
  end
end
