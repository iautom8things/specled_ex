defmodule SpecLedEx.AppendOnlyTest do
  # covers: specled.append_only.requirement_deleted specled.append_only.must_downgraded specled.append_only.scenario_regression specled.append_only.negative_removed specled.append_only.disabled_without_reason specled.append_only.no_baseline specled.append_only.adr_affects_widened specled.append_only.same_pr_self_authorization specled.append_only.missing_change_type specled.append_only.decision_deleted specled.append_only.identity specled.append_only.findings_sorted specled.append_only.fix_block_discipline
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.append_only.adr_affects_widened", "specled.append_only.decision_deleted", "specled.append_only.disabled_without_reason", "specled.append_only.findings_sorted", "specled.append_only.fix_block_discipline", "specled.append_only.identity", "specled.append_only.missing_change_type", "specled.append_only.must_downgraded", "specled.append_only.negative_removed", "specled.append_only.no_baseline", "specled.append_only.requirement_deleted", "specled.append_only.requirement_deleted_authorized", "specled.append_only.same_pr_self_authorization", "specled.append_only.scenario_regression"]
  use ExUnitProperties

  import SpecLedEx.AppendOnlyFixtures

  alias SpecLedEx.AppendOnly

  describe "requirement_deleted" do
    test "unauthorized removal emits append_only/requirement_deleted at :error" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST reject invalid input.")]
        )

      current = state_fixture(subject: "x", requirements: [])

      assert [finding] = AppendOnly.analyze(prior, current, [])
      assert finding.code == "append_only/requirement_deleted"
      assert finding.severity == :error
      assert finding.subject_id == "x"
      assert finding.entity_id == "x.req_a"
      assert fix_block_present?(finding.message)
    end

    test "weakening-set ADR in prior-landed decisions suppresses the finding" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST reject invalid input.")],
          decisions: [adr(id: "d1", affects: ["x.req_a"], change_type: "deprecates",
                          reverses_what: "Legacy anti-spam guard retired.")]
        )

      current = state_fixture(subject: "x", requirements: [], decisions: [])

      # ADR d1 is in prior — the id remains in decisions_by_id for both, so
      # decision_deleted would fire since current has no d1. Keep d1 in current
      # to test just the authorization path.
      current_with_adr =
        state_fixture(
          subject: "x",
          requirements: [],
          decisions: [adr(id: "d1", affects: ["x.req_a"], change_type: "deprecates",
                          reverses_what: "Legacy anti-spam guard retired.")]
        )

      head_decisions = [
        adr(id: "d1", affects: ["x.req_a"], change_type: "deprecates",
            reverses_what: "Legacy anti-spam guard retired.", form: :parsed)
      ]

      # Authorized path: no requirement_deleted finding.
      assert [] == AppendOnly.analyze(prior, current_with_adr, head_decisions)
      refute is_nil(current)
    end

    test "non-weakening change_type (clarifies) does not authorize removal" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "Statement.")]
        )

      current = state_fixture(subject: "x", requirements: [])

      head_decisions = [
        adr(id: "d1", affects: ["x.req_a"], change_type: "clarifies", form: :parsed)
      ]

      assert Enum.any?(
               AppendOnly.analyze(prior, current, head_decisions),
               &(&1.code == "append_only/requirement_deleted")
             )
    end
  end

  describe "must_downgraded" do
    test "MUST -> SHOULD in statement emits append_only/must_downgraded" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST reject invalid input.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system SHOULD reject invalid input.")]
        )

      assert [finding] = AppendOnly.analyze(prior, current, [])
      assert finding.code == "append_only/must_downgraded"
      assert finding.severity == :error
      assert finding.entity_id == "x.req_a"
      assert fix_block_present?(finding.message)
    end

    test "MUST -> <no modal> emits append_only/must_downgraded" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST reject invalid input.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system rejects invalid input.")]
        )

      assert Enum.any?(
               AppendOnly.analyze(prior, current, []),
               &(&1.code == "append_only/must_downgraded")
             )
    end

    test "MUST -> MUST NOT (cross-polarity) emits append_only/must_downgraded" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST reject invalid input.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST NOT reject invalid input.")]
        )

      assert Enum.any?(
               AppendOnly.analyze(prior, current, []),
               &(&1.code == "append_only/must_downgraded")
             )
    end

    test "weakening-set ADR suppresses must_downgraded" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST reject invalid input.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system SHOULD reject invalid input.")]
        )

      head_decisions = [
        adr(id: "d1", affects: ["x.req_a"], change_type: "weakens",
            reverses_what: "SLAs lowered to industry baseline for v1.",
            form: :parsed)
      ]

      refute Enum.any?(
               AppendOnly.analyze(prior, current, head_decisions),
               &(&1.code == "append_only/must_downgraded")
             )
    end
  end

  describe "scenario_regression" do
    test "coverage count drop emits append_only/scenario_regression" do
      req = requirement("x.req_a", "The system MUST foo.")

      prior =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [
            scenario(id: "x.scenario.one", covers: ["x.req_a"]),
            scenario(id: "x.scenario.two", covers: ["x.req_a"])
          ]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [scenario(id: "x.scenario.one", covers: ["x.req_a"])]
        )

      assert [finding] = AppendOnly.analyze(prior, current, [])
      assert finding.code == "append_only/scenario_regression"
      assert finding.severity == :error
      assert finding.entity_id == "x.req_a"
      assert fix_block_present?(finding.message)
    end

    test "count stable produces no finding" do
      req = requirement("x.req_a", "The system MUST foo.")

      state =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [scenario(id: "x.scenario.one", covers: ["x.req_a"])]
        )

      assert [] == AppendOnly.analyze(state, state, [])
    end

    test "count increase produces no finding" do
      req = requirement("x.req_a", "The system MUST foo.")

      prior =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [scenario(id: "x.scenario.one", covers: ["x.req_a"])]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [
            scenario(id: "x.scenario.one", covers: ["x.req_a"]),
            scenario(id: "x.scenario.two", covers: ["x.req_a"])
          ]
        )

      assert [] == AppendOnly.analyze(prior, current, [])
    end

    test "weakening-set ADR suppresses scenario_regression" do
      req = requirement("x.req_a", "The system MUST foo.")

      prior =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [
            scenario(id: "x.scenario.one", covers: ["x.req_a"]),
            scenario(id: "x.scenario.two", covers: ["x.req_a"])
          ]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [req],
          scenarios: [scenario(id: "x.scenario.one", covers: ["x.req_a"])]
        )

      head_decisions = [
        adr(id: "d1", affects: ["x.req_a"], change_type: "narrows-scope",
            reverses_what: "Outer-loop scenario dropped; replacement covers primary path.",
            form: :parsed)
      ]

      assert [] == AppendOnly.analyze(prior, current, head_decisions)
    end
  end

  describe "negative_removed" do
    test "explicit polarity: negative -> absent emits append_only/negative_removed" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [
            requirement("x.req_a", "The system MUST NOT leak session tokens.", polarity: "negative")
          ]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system handles session tokens.")]
        )

      assert Enum.any?(
               AppendOnly.analyze(prior, current, []),
               &(&1.code == "append_only/negative_removed")
             )
    end

    test "inferred negative (MUST NOT stem) removed emits append_only/negative_removed" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST NOT log passwords.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system handles passwords carefully.")]
        )

      assert Enum.any?(
               AppendOnly.analyze(prior, current, []),
               &(&1.code == "append_only/negative_removed")
             )
    end

    test "weakening-set ADR suppresses negative_removed" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [
            requirement("x.req_a", "The system MUST NOT leak session tokens.", polarity: "negative")
          ]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system handles session tokens.")]
        )

      head_decisions = [
        adr(id: "d1", affects: ["x.req_a"], change_type: "adds-exception",
            reverses_what: "Session-token exception added for the debug flow.",
            form: :parsed)
      ]

      refute Enum.any?(
               AppendOnly.analyze(prior, current, head_decisions),
               &(&1.code == "append_only/negative_removed")
             )
    end
  end

  describe "disabled_without_reason" do
    test "execute: false without reason emits warning" do
      current =
        state_fixture(
          subject: "x",
          scenarios: [
            scenario(
              id: "x.scenario.one",
              covers: ["x.req_a"],
              execute: false
            )
          ]
        )

      assert [finding] = AppendOnly.analyze(current, current, [])
      assert finding.code == "append_only/disabled_without_reason"
      assert finding.severity == :warning
      assert finding.entity_id == "x.scenario.one"
      assert fix_block_present?(finding.message)
    end

    test "execute: false with non-empty reason is clean" do
      current =
        state_fixture(
          subject: "x",
          scenarios: [
            scenario(
              id: "x.scenario.one",
              covers: ["x.req_a"],
              execute: false,
              reason: "Blocked on upstream fixture; re-enable in sprint 14."
            )
          ]
        )

      assert [] == AppendOnly.analyze(current, current, [])
    end

    test "execute: true (or absent) is clean" do
      current =
        state_fixture(
          subject: "x",
          scenarios: [scenario(id: "x.scenario.one", covers: ["x.req_a"])]
        )

      assert [] == AppendOnly.analyze(current, current, [])
    end
  end

  describe "no_baseline" do
    test ":missing prior emits exactly one :info finding" do
      current =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "The system MUST foo.")]
        )

      assert [finding] = AppendOnly.analyze(:missing, current, [])
      assert finding.code == "append_only/no_baseline"
      assert finding.severity == :info
      assert fix_block_present?(finding.message)
    end

    test "no_baseline carries the variant tag in its message" do
      current = state_fixture()

      assert [first_run] = AppendOnly.analyze(:missing, current, [])
      assert first_run.message =~ "first-run bootstrap"

      assert [shallow] = AppendOnly.analyze(:missing, current, [], baseline_variant: :shallow_clone)
      assert shallow.message =~ "shallow-clone"

      assert [bad] = AppendOnly.analyze(:missing, current, [], baseline_variant: :bad_ref)
      assert bad.message =~ "bad base ref"
    end

    test ":missing suppresses every other append_only/* finding" do
      # Even with a state that would otherwise trip many detectors.
      current =
        state_fixture(
          subject: "x",
          scenarios: [scenario(id: "x.scenario.one", covers: ["x.req_a"], execute: false)],
          decisions: [adr(id: "d1", affects: ["nope"], change_type: "weakens",
                          reverses_what: "nope")]
        )

      findings = AppendOnly.analyze(:missing, current, [])
      assert length(findings) == 1
      assert hd(findings).code == "append_only/no_baseline"
    end
  end

  describe "adr_affects_widened" do
    test "affects list changes on an accepted ADR emits error" do
      d1_prior = adr(id: "d1", status: "accepted", affects: ["x.req_a"],
                     change_type: "weakens", reverses_what: "Old reason.")

      d1_current = adr(id: "d1", status: "accepted", affects: ["x.req_a", "x.req_b"],
                       change_type: "weakens", reverses_what: "Old reason.")

      prior = state_fixture(subject: "x", decisions: [d1_prior])
      current = state_fixture(subject: "x", decisions: [d1_current])

      assert [finding] = AppendOnly.analyze(prior, current, [])
      assert finding.code == "append_only/adr_affects_widened"
      assert finding.severity == :error
      assert finding.entity_id == "d1"
      assert fix_block_present?(finding.message)
    end

    test "change_type change on an accepted ADR emits the finding" do
      d1_prior = adr(id: "d1", status: "accepted", affects: ["x.req_a"],
                     change_type: "weakens", reverses_what: "Reason.")

      d1_current = adr(id: "d1", status: "accepted", affects: ["x.req_a"],
                       change_type: "narrows-scope", reverses_what: "Reason.")

      prior = state_fixture(subject: "x", decisions: [d1_prior])
      current = state_fixture(subject: "x", decisions: [d1_current])

      assert Enum.any?(
               AppendOnly.analyze(prior, current, []),
               &(&1.code == "append_only/adr_affects_widened")
             )
    end

    test "non-accepted ADR (e.g. deprecated) can drift without emitting" do
      d1_prior = adr(id: "d1", status: "deprecated", affects: ["x.req_a"],
                     change_type: "deprecates", reverses_what: "Reason.")

      d1_current = adr(id: "d1", status: "deprecated", affects: ["x.req_a", "x.req_b"],
                       change_type: "deprecates", reverses_what: "Reason.")

      prior = state_fixture(subject: "x", decisions: [d1_prior])
      current = state_fixture(subject: "x", decisions: [d1_current])

      refute Enum.any?(
               AppendOnly.analyze(prior, current, []),
               &(&1.code == "append_only/adr_affects_widened")
             )
    end
  end

  describe "same_pr_self_authorization" do
    test "new ADR authorizing exactly the removed-ids set emits warning and suppresses requirement_deleted" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "Old MUST.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [],
          decisions: [
            adr(id: "d1", affects: ["x.req_a"], change_type: "deprecates",
                reverses_what: "Requirement retired for v2.")
          ]
        )

      head_decisions = [
        adr(id: "d1", affects: ["x.req_a"], change_type: "deprecates",
            reverses_what: "Requirement retired for v2.", form: :parsed)
      ]

      findings = AppendOnly.analyze(prior, current, head_decisions)

      refute Enum.any?(findings, &(&1.code == "append_only/requirement_deleted"))
      assert [warning] = Enum.filter(findings, &(&1.code == "append_only/same_pr_self_authorization"))
      assert warning.severity == :warning
      assert warning.entity_id == "d1"
      assert fix_block_present?(warning.message)
    end

    test "ADR authoring affects superset of removed ids is not self-authorizing (exact match required)" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "Old MUST.")]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [],
          decisions: []
        )

      # affects includes x.req_b which was NOT removed → not exact match → no warning.
      head_decisions = [
        adr(id: "d1", affects: ["x.req_a", "x.req_b"], change_type: "deprecates",
            reverses_what: "Multi-id retirement", form: :parsed)
      ]

      findings = AppendOnly.analyze(prior, current, head_decisions)

      refute Enum.any?(findings, &(&1.code == "append_only/same_pr_self_authorization"))
      # The ADR still authorizes the deletion (weakening-set + id in affects),
      # so no requirement_deleted either — the authorization is non-self.
      refute Enum.any?(findings, &(&1.code == "append_only/requirement_deleted"))
    end
  end

  describe "missing_change_type" do
    test "head ADR referenced by authorization lookup without change_type emits warning" do
      prior =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "MUST foo.")]
        )

      current = state_fixture(subject: "x", requirements: [])

      # ADR lists x.req_a in affects but has no change_type.
      head_decisions = [
        adr(id: "d2", affects: ["x.req_a"], form: :parsed)
      ]

      findings = AppendOnly.analyze(prior, current, head_decisions)

      assert Enum.any?(
               findings,
               &(&1.code == "append_only/missing_change_type" and &1.severity == :warning and
                   &1.entity_id == "d2")
             )

      # And the deletion still fires because missing_change_type does not authorize.
      assert Enum.any?(findings, &(&1.code == "append_only/requirement_deleted"))
    end

    test "ADR never consulted by an authorization lookup does not emit the warning" do
      state =
        state_fixture(
          subject: "x",
          requirements: [requirement("x.req_a", "MUST foo.")]
        )

      # No weakening events at all — consulted_ids is empty.
      head_decisions = [
        adr(id: "d2", affects: ["x.req_a"], form: :parsed)
      ]

      refute Enum.any?(
               AppendOnly.analyze(state, state, head_decisions),
               &(&1.code == "append_only/missing_change_type")
             )
    end
  end

  describe "decision_deleted" do
    test "prior ADR id absent from current state emits error" do
      d1 = adr(id: "d1", status: "accepted", affects: ["x.req_a"],
               change_type: "weakens", reverses_what: "Reason.")

      prior = state_fixture(subject: "x", decisions: [d1])
      current = state_fixture(subject: "x", decisions: [])

      assert [finding] = AppendOnly.analyze(prior, current, [])
      assert finding.code == "append_only/decision_deleted"
      assert finding.severity == :error
      assert finding.entity_id == "d1"
      assert fix_block_present?(finding.message)
    end

    test "ADR present in both is fine" do
      d1 = adr(id: "d1", status: "accepted", affects: ["x.req_a"],
               change_type: "weakens", reverses_what: "Reason.")

      state = state_fixture(subject: "x", decisions: [d1])
      assert [] == AppendOnly.analyze(state, state, [])
    end
  end

  describe "identity + sorting + fix-block discipline" do
    test "analyze(s, s, []) returns [] over a populated state" do
      state =
        state_fixture(
          subject: "x",
          requirements: [
            requirement("x.req_a", "The system MUST foo."),
            requirement("x.req_b", "The system MUST NOT bar.", polarity: "negative")
          ],
          scenarios: [
            scenario(id: "x.scenario.one", covers: ["x.req_a"]),
            scenario(id: "x.scenario.two", covers: ["x.req_b"])
          ],
          decisions: [
            adr(id: "d1", status: "accepted", affects: ["x.req_a"],
                change_type: "weakens", reverses_what: "Reason.")
          ]
        )

      assert [] == AppendOnly.analyze(state, state, [])
    end

    test "findings are sorted by {subject_id, entity_id, code}" do
      # A diff that produces multiple findings across two subjects.
      prior =
        state_fixture(
          subject: "a",
          requirements: [
            requirement("a.req_a", "The system MUST foo."),
            requirement("a.req_b", "The system MUST bar.")
          ],
          subjects: [
            %{
              "id" => "a",
              "file" => ".spec/specs/a.spec.md",
              "title" => "A",
              "meta" => %{"id" => "a"}
            },
            %{
              "id" => "b",
              "file" => ".spec/specs/b.spec.md",
              "title" => "B",
              "meta" => %{"id" => "b"}
            }
          ]
        )

      # Keep only one requirement from subject "a" and append a requirement from "b"
      # that is being removed — we craft prior/current so both subjects lose reqs.
      prior2 =
        state_fixture(
          requirements: [
            requirement("a.req_a", "The system MUST foo.", subject_id: "a"),
            requirement("a.req_b", "The system MUST bar.", subject_id: "a"),
            requirement("b.req_c", "The system MUST baz.", subject_id: "b")
          ],
          subjects: [
            %{"id" => "a", "file" => ".spec/specs/a.spec.md", "title" => "A", "meta" => %{"id" => "a"}},
            %{"id" => "b", "file" => ".spec/specs/b.spec.md", "title" => "B", "meta" => %{"id" => "b"}}
          ]
        )

      current2 = state_fixture(requirements: [], subjects: prior2["index"]["subjects"])

      findings = AppendOnly.analyze(prior2, current2, [])

      keys = Enum.map(findings, &{&1.subject_id || "", &1.entity_id || "", &1.code || ""})
      assert keys == Enum.sort(keys)

      # Validate subject-scoped keys are grouped (a before b).
      subject_ids = Enum.map(findings, & &1.subject_id)
      assert subject_ids == Enum.sort(subject_ids)

      _ = prior
    end

    test "every append_only/* message carries a code-fenced fix: block" do
      # Produce a broad mix of findings.
      prior =
        state_fixture(
          subject: "x",
          requirements: [
            requirement("x.req_a", "The system MUST foo."),
            requirement("x.req_b", "The system MUST NOT bar.", polarity: "negative")
          ],
          scenarios: [
            scenario(id: "x.scenario.one", covers: ["x.req_a"]),
            scenario(id: "x.scenario.two", covers: ["x.req_a"])
          ],
          decisions: [
            adr(id: "d1", status: "accepted", affects: ["x.req_a"],
                change_type: "weakens", reverses_what: "Old reason.")
          ]
        )

      current =
        state_fixture(
          subject: "x",
          requirements: [
            requirement("x.req_a", "The system SHOULD foo."),
            requirement("x.req_b", "The system handles bar.")
          ],
          scenarios: [
            scenario(id: "x.scenario.one", covers: ["x.req_a"]),
            scenario(id: "x.scenario.three", covers: ["x.req_a"], execute: false)
          ],
          decisions: [
            adr(id: "d1", status: "accepted", affects: ["x.req_a", "x.req_z"],
                change_type: "weakens", reverses_what: "Old reason.")
          ]
        )

      findings = AppendOnly.analyze(prior, current, [])
      assert findings != []

      for finding <- findings do
        assert String.starts_with?(finding.code, "append_only/"),
               "unexpected finding code: #{inspect(finding.code)}"

        assert fix_block_present?(finding.message),
               "no fix: block in #{finding.code}: #{inspect(finding.message)}"
      end
    end
  end

  describe "properties" do
    property "identity: analyze(s, s, []) == [] for any generated populated state" do
      check all(req_ids <- uniq_list_of(id_generator(), min_length: 1, max_length: 4)) do
        reqs = Enum.map(req_ids, &requirement(&1, "The system MUST foo.", subject_id: "x"))
        state = state_fixture(subject: "x", requirements: reqs)
        assert [] == AppendOnly.analyze(state, state, [])
      end
    end

    property "bootstrap: :missing prior yields exactly one no_baseline finding regardless of current content" do
      check all(req_ids <- uniq_list_of(id_generator(), min_length: 0, max_length: 4)) do
        reqs = Enum.map(req_ids, &requirement(&1, "The system MUST foo.", subject_id: "x"))
        state = state_fixture(subject: "x", requirements: reqs)
        findings = AppendOnly.analyze(:missing, state, [])
        assert length(findings) == 1
        assert hd(findings).code == "append_only/no_baseline"
      end
    end
  end

  defp fix_block_present?(message) when is_binary(message) do
    # Message must end with a closing ``` and carry a fix: line within the final fence.
    trimmed = String.trim_trailing(message)
    String.ends_with?(trimmed, "```") and String.contains?(trimmed, "\nfix:")
  end

  defp id_generator do
    StreamData.bind(StreamData.integer(1..1000), fn n ->
      StreamData.constant("x.req_#{n}")
    end)
  end
end
