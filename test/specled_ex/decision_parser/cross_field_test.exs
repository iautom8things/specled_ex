defmodule SpecLedEx.DecisionParser.CrossFieldTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.decisions.change_type_enum", "specled.decisions.change_type_optional", "specled.decisions.cross_field_adr_append_only", "specled.decisions.cross_field_affects_non_empty", "specled.decisions.cross_field_affects_resolve", "specled.decisions.cross_field_idempotent", "specled.decisions.cross_field_reverses_what", "specled.decisions.cross_field_supersedes_replaces", "specled.decisions.frontmatter_contract", "specled.decisions.reference_validation", "specled.decisions.weakening_set"]

  alias SpecLedEx.DecisionParser.CrossField

  # ---- test helpers ----

  defp decision(meta) do
    %{
      "file" => ".spec/decisions/example.md",
      "title" => "Example",
      "meta" => meta,
      "sections" => ["Context", "Decision", "Consequences"],
      "parse_errors" => []
    }
  end

  defp index(opts \\ []) do
    subjects =
      Keyword.get(opts, :subjects, [])
      |> Enum.map(fn
        {id, req_ids} ->
          %{"meta" => %{"id" => id}, "requirements" => Enum.map(req_ids, &%{"id" => &1})}

        id ->
          %{"meta" => %{"id" => id}, "requirements" => []}
      end)

    decisions =
      Keyword.get(opts, :decisions, [])
      |> Enum.map(fn id -> %{"meta" => %{"id" => id}} end)

    %{"subjects" => subjects, "decisions" => decisions}
  end

  defp codes_in(errors), do: Enum.map(errors, & &1.code)

  # ---- R1 ----

  describe "rule 1: supersedes requires replaces" do
    test "emits error when replaces is missing" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"],
          "change_type" => "supersedes"
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"]))
      assert "cross_field/supersedes_missing_replaces" in codes_in(errors)
    end

    test "emits error when a replaces id does not resolve" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"],
          "change_type" => "supersedes",
          "replaces" => ["missing.one"]
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"]))
      assert "cross_field/supersedes_unresolved_replaces" in codes_in(errors)
    end

    test "passes when every replaces id resolves in the index" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"],
          "change_type" => "supersedes",
          "replaces" => ["adr.previous"]
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"], decisions: ["adr.previous"]))
      refute "cross_field/supersedes_missing_replaces" in codes_in(errors)
      refute "cross_field/supersedes_unresolved_replaces" in codes_in(errors)
    end
  end

  # ---- R2 ----

  describe "rule 2: weakening change_type requires reverses_what" do
    test "emits error when reverses_what is blank for deprecates" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"],
          "change_type" => "deprecates",
          "reverses_what" => "   "
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"]))
      assert "cross_field/reverses_what_missing" in codes_in(errors)
    end

    test "passes when reverses_what is present for a weakening change_type" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"],
          "change_type" => "weakens",
          "reverses_what" => "original requirement was too strong"
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"]))
      refute "cross_field/reverses_what_missing" in codes_in(errors)
    end

    test "does not require reverses_what for clarifies or refines" do
      for ct <- ["clarifies", "refines"] do
        d =
          decision(%{
            "id" => "adr.a",
            "status" => "accepted",
            "affects" => ["subj.x"],
            "change_type" => ct
          })

        errors = CrossField.validate(d, index(subjects: ["subj.x"]))
        refute "cross_field/reverses_what_missing" in codes_in(errors)
      end
    end
  end

  # ---- R3 ----

  describe "rule 3: affects non-empty for non-clarifies change_type" do
    test "emits error for weakens with empty affects" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => [],
          "change_type" => "weakens",
          "reverses_what" => "because"
        })

      errors = CrossField.validate(d, index())
      assert "cross_field/affects_empty" in codes_in(errors)
    end

    test "clarifies is exempt from the non-empty affects requirement" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => [],
          "change_type" => "clarifies"
        })

      errors = CrossField.validate(d, index())
      refute "cross_field/affects_empty" in codes_in(errors)
    end
  end

  # ---- R4 ----

  describe "rule 4: affects must resolve in current index" do
    test "emits error when an affects id does not resolve" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.nope"],
          "change_type" => "narrows-scope",
          "reverses_what" => "scope is too broad"
        })

      errors = CrossField.validate(d, index(subjects: [{"subj.x", ["subj.x.req_1"]}]))
      assert "cross_field/affects_unresolved" in codes_in(errors)
    end

    test "passes when affects resolves to a requirement id" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x.req_1"],
          "change_type" => "narrows-scope",
          "reverses_what" => "scope is too broad"
        })

      errors = CrossField.validate(d, index(subjects: [{"subj.x", ["subj.x.req_1"]}]))
      refute "cross_field/affects_unresolved" in codes_in(errors)
    end
  end

  # ---- R5 ----

  describe "rule 5: ADR append-only structural immutability" do
    setup do
      base_meta = %{
        "id" => "adr.a",
        "status" => "accepted",
        "affects" => ["subj.x"],
        "change_type" => "weakens",
        "reverses_what" => "original"
      }

      prior = [%{"meta" => base_meta}]

      {:ok, base_meta: base_meta, prior: prior}
    end

    test "passes for an unchanged accepted ADR", %{base_meta: meta, prior: prior} do
      errors = CrossField.validate(decision(meta), index(subjects: ["subj.x"]), prior_decisions: prior)
      refute "cross_field/adr_field_drift" in codes_in(errors)
      refute "cross_field/adr_status_regression" in codes_in(errors)
    end

    test "detects drift on affects", %{base_meta: meta, prior: prior} do
      changed = %{meta | "affects" => ["subj.x", "subj.y"]}
      errors = CrossField.validate(decision(changed), index(subjects: ["subj.x", "subj.y"]), prior_decisions: prior)
      assert "cross_field/adr_field_drift" in codes_in(errors)
    end

    test "detects drift on change_type", %{base_meta: meta, prior: prior} do
      changed = %{meta | "change_type" => "narrows-scope"}
      errors = CrossField.validate(decision(changed), index(subjects: ["subj.x"]), prior_decisions: prior)
      assert "cross_field/adr_field_drift" in codes_in(errors)
    end

    test "detects drift on reverses_what", %{base_meta: meta, prior: prior} do
      changed = %{meta | "reverses_what" => "something else"}
      errors = CrossField.validate(decision(changed), index(subjects: ["subj.x"]), prior_decisions: prior)
      assert "cross_field/adr_field_drift" in codes_in(errors)
    end

    test "accepts accepted -> deprecated status transition", %{base_meta: meta, prior: prior} do
      changed = %{meta | "status" => "deprecated"}
      errors = CrossField.validate(decision(changed), index(subjects: ["subj.x"]), prior_decisions: prior)
      refute "cross_field/adr_status_regression" in codes_in(errors)
    end

    test "accepts accepted -> superseded status transition", %{base_meta: meta, prior: prior} do
      changed = %{meta | "status" => "superseded"}
      errors = CrossField.validate(decision(changed), index(subjects: ["subj.x"]), prior_decisions: prior)
      refute "cross_field/adr_status_regression" in codes_in(errors)
    end

    test "rejects deprecated -> accepted reverse transition", %{prior: _} do
      base = %{
        "id" => "adr.a",
        "status" => "deprecated",
        "affects" => ["subj.x"],
        "change_type" => "weakens",
        "reverses_what" => "original"
      }

      head = %{base | "status" => "accepted"}
      prior = [%{"meta" => base}]

      errors = CrossField.validate(decision(head), index(subjects: ["subj.x"]), prior_decisions: prior)
      assert "cross_field/adr_status_regression" in codes_in(errors)
    end

    test "is disabled when prior_decisions is absent or nil" do
      changed = %{
        "id" => "adr.a",
        "status" => "accepted",
        "affects" => ["subj.x", "subj.y"],
        "change_type" => "narrows-scope",
        "reverses_what" => "drift"
      }

      errors = CrossField.validate(decision(changed), index(subjects: ["subj.x", "subj.y"]))
      refute "cross_field/adr_field_drift" in codes_in(errors)
      refute "cross_field/adr_status_regression" in codes_in(errors)
    end
  end

  # ---- R6 (complement of R1.a) ----

  describe "rule 6: deprecates affects do not need to resolve" do
    test "deprecates can target ids absent from the current index" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.gone"],
          "change_type" => "deprecates",
          "reverses_what" => "requirement retired"
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"]))
      refute "cross_field/affects_unresolved" in codes_in(errors)
    end
  end

  # ---- R7 ----

  describe "rule 7: missing change_type is a warning" do
    test "emits a warning-severity finding when change_type is absent" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"]
        })

      [warning | _] =
        d
        |> CrossField.validate(index(subjects: ["subj.x"]))
        |> Enum.filter(&(&1.code == "cross_field/missing_change_type"))

      assert warning.severity == :warning
    end

    test "no warning when change_type is present" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.x"],
          "change_type" => "clarifies"
        })

      errors = CrossField.validate(d, index(subjects: ["subj.x"]))
      refute "cross_field/missing_change_type" in codes_in(errors)
    end
  end

  # ---- idempotence property (T8 #4) ----

  describe "idempotence" do
    test "repeated invocation returns identical output" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.missing"],
          "change_type" => "supersedes"
        })

      idx = index(subjects: ["subj.x"])
      first = CrossField.validate(d, idx)
      second = CrossField.validate(d, idx)
      third = CrossField.validate(d, idx)

      assert first == second
      assert second == third
    end

    test "running validate over the cross-field errors themselves does not grow them" do
      d =
        decision(%{
          "id" => "adr.a",
          "status" => "accepted",
          "affects" => ["subj.missing"],
          "change_type" => "supersedes"
        })

      idx = index()
      errors_once = CrossField.validate(d, idx)
      errors_twice = CrossField.validate(d, idx) ++ CrossField.validate(d, idx)

      assert length(errors_twice) == 2 * length(errors_once)
      assert Enum.all?(errors_twice, fn e -> e in errors_once end)
    end
  end
end
