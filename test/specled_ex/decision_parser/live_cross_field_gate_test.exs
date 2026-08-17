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

  defp verify_strict(index, root, opts \\ []) do
    SpecLedEx.validate(index, root, Keyword.merge([strict: true, run_commands: false], opts))
  end

  # A bare `assert report["status"] == "pass"` couples this file to every default
  # finding the verifier emits: add an unrelated default check upstream and these
  # tests fail with `left: "fail" / right: "pass"` and no hint that the cause is
  # elsewhere. Naming the offending findings in the failure keeps the global
  # assertion — which is the actual adopter-facing claim — while making a
  # collision diagnosable in one read.
  defp assert_gate_passes(report) do
    assert report["status"] == "pass",
           "expected a clean gate, got findings: #{inspect(report["findings"], pretty: true)}"
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

    # R7's negative half on the live path: a well-formed ADR produces no warning,
    # and the warning counter does not double as an error counter.
    assert decision_by_id(index, "adr.resolves")["parse_warnings"] == []
    assert index["summary"]["decision_parse_warnings"] == 0

    report = verify_strict(index, root)

    assert_gate_passes(report)
  end

  # The 0.15.0 escape: three narrows-scope ADRs with no `reverses_what:` shipped
  # and `mix spec.check` returned pass, because nothing on the live path ran R2.
  @tag spec: [
         "specled.decisions.cross_field_reverses_what",
         "specled.decisions.cross_field_live_gate"
       ]
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

    assert index["summary"]["decision_parse_warnings"] == 0

    report = verify_strict(index, root)

    assert report["status"] == "fail"

    assert Enum.any?(report["findings"], fn finding ->
             finding["severity"] == "error" and
               finding["code"] == "decision_parse_error" and
               finding["message"] =~ "cross_field/reverses_what_missing"
           end)
  end

  @tag spec: [
         "specled.decisions.cross_field_affects_resolve",
         "specled.decisions.cross_field_live_gate"
       ]
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

    report = verify_strict(index, root)

    assert report["status"] == "fail"

    # The status alone proves nothing here: the verifier's own
    # `decision_unknown_affect` check already rejects this ADR and predates the
    # live gate, so the gate could be fully unwired and the status would still
    # be "fail". Pin the cross-field finding itself.
    assert Enum.any?(report["findings"], fn finding ->
             finding["severity"] == "error" and
               finding["code"] == "decision_parse_error" and
               finding["message"] =~ "cross_field/affects_unresolved"
           end)
  end

  # `mix spec.check` validates with strict: true, where a warning-severity
  # finding fails the gate exactly like an error. Reporting the missing
  # change_type at warning severity would therefore break every workspace
  # holding a legacy ADR — the outcome change_type_optional exists to prevent.
  @tag spec: [
         "specled.decisions.change_type_optional",
         "specled.decisions.cross_field_live_gate"
       ]
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

    report = verify_strict(index, root)

    assert_gate_passes(report)

    assert [warning] =
             Enum.filter(report["findings"], &(&1["code"] == "decision_cross_field_warning"))

    assert warning["severity"] == "info"
    assert warning["message"] =~ "cross_field/missing_change_type"
  end

  # The other half of the info default: it is a default, not a mute. Both the
  # requirement and specled.decision.live_cross_field_gate promise adopters can
  # raise the code through `verification.severities`, so the promise is tested.
  @tag spec: "specled.decisions.cross_field_live_gate"
  test "an adopter can raise the cross-field warning to a gate failure", %{root: root} do
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

    report =
      verify_strict(index, root, severities: %{"decision_cross_field_warning" => :error})

    assert report["status"] == "fail"

    assert [raised] =
             Enum.filter(report["findings"], &(&1["code"] == "decision_cross_field_warning"))

    assert raised["severity"] == "error"
  end

  # `mix spec.check --debug` is what a maintainer reaches for when a verdict is
  # confusing, and an `info`-severity cross-field warning is exactly the class of
  # diagnostic that is invisible at default severity — the debug check line is the
  # only place it surfaces explicitly. Deleting the debug pipeline stage left the
  # whole suite green before this test existed.
  @tag spec: "specled.decisions.cross_field_live_gate"
  test "cross-field warnings surface as debug checks", %{root: root} do
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
    report = verify_strict(index, root, debug: true)

    assert [check] =
             Enum.filter(report["checks"], &(&1["code"] == "decision_cross_field_warning"))

    assert check["status"] == "info"
    assert check["message"] =~ "cross_field/missing_change_type"
    assert check["subject_id"] == "adr.legacy"
  end

  # ADR frontmatter is unvalidated YAML, so a field can decode to a mapping or a
  # list. Blanket `to_string/1` on one raises Protocol.UndefinedError, and because
  # `Mix.Tasks.Spec.Check` wraps `SpecLedEx.index/2` in no rescue, that aborts the
  # whole gate: no findings, no verdict line, and every unrelated diagnostic in
  # the run is lost too. A gate that cannot report is worse than one that reports
  # badly, so each malformed shape must degrade to a diagnostic.
  @tag spec: [
         "specled.decisions.cross_field_reverses_what",
         "specled.decisions.cross_field_live_gate"
       ]
  test "malformed frontmatter shapes report instead of aborting the gate", %{root: root} do
    write_workspace(root)

    # reverses_what as a nested mapping — the shape that crashed R2.
    write_decision(
      root,
      "mapping_rw",
      adr("adr.mapping_rw", """
      change_type: narrows-scope
      reverses_what:
        why: it used to be broader
      affects:
        - alpha.requirement
      """)
    )

    # change_type as a mapping — names no enum member, so R7 treats it as absent.
    write_decision(
      root,
      "mapping_ct",
      adr("adr.mapping_ct", """
      change_type:
        kind: narrows-scope
      affects:
        - alpha.requirement
      """)
    )

    # A non-string affects element — must surface, not silently shrink the list.
    write_decision(
      root,
      "listy_affects",
      adr("adr.listy_affects", """
      change_type: narrows-scope
      reverses_what: >-
        Something used to be broader.
      affects:
        - nested: alpha.requirement
      """)
    )

    index = Index.build(root, test_tags: false)

    assert ["cross_field/reverses_what_missing: " <> _] =
             decision_by_id(index, "adr.mapping_rw")["parse_errors"]

    assert ["cross_field/missing_change_type: " <> _] =
             decision_by_id(index, "adr.mapping_ct")["parse_warnings"]

    assert ["cross_field/affects_unresolved: " <> unresolved] =
             decision_by_id(index, "adr.listy_affects")["parse_errors"]

    assert unresolved =~ "nested"

    # And the run still produces a report rather than a stacktrace.
    report = verify_strict(index, root)
    assert report["status"] == "fail"
  end

  # `validate_cross_fields/3` is public API: an out-of-repo caller can hand it a
  # decision map it built or cached itself, without the "parse_warnings" key the
  # in-tree parse_file/4 seeds. Nothing else in the suite feeds it that shape, so
  # `Map.update!/3` in push_parse_warning/2 would raise KeyError on those callers
  # with every other test still green.
  @tag spec: "specled.decisions.cross_field_live_gate"
  test "a decision map with no parse_warnings key gains one instead of raising" do
    legacy = %{
      "file" => ".spec/decisions/legacy.md",
      "title" => "Legacy",
      "meta" => %{"id" => "adr.legacy", "status" => "accepted", "affects" => ["alpha.subject"]},
      "sections" => ["Context", "Decision", "Consequences"],
      "parse_errors" => []
    }

    refute Map.has_key?(legacy, "parse_warnings")

    index = %{"subjects" => [%{"meta" => %{"id" => "alpha.subject"}}], "decisions" => []}

    assert [validated] = SpecLedEx.DecisionParser.validate_cross_fields([legacy], index)

    assert ["cross_field/missing_change_type: " <> _] = validated["parse_warnings"]
    assert validated["parse_errors"] == []
  end
end
