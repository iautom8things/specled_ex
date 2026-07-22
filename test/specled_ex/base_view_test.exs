defmodule SpecLedEx.BaseViewTest do
  use SpecLedEx.Case

  alias SpecLedEx.BaseView

  @moduletag spec: [
               "specled.index.base_view_parses_base_sources",
               "specled.branch_guard.base_view_prior_state"
             ]

  @decision """
  ---
  id: specled.decision.billing_split
  status: accepted
  date: 2026-07-16
  affects:
    - billing.invoice
  change_type: deprecates
  reverses_what: Legacy invoice coupling.
  ---

  # Billing Split

  ## Context

  Billing changed.

  ## Decision

  Split it.

  ## Consequences

  Explicit reversal is recorded.
  """

  @tag spec: "specled.index.base_view_parses_base_sources"
  test "base tree specs and decisions parse to the same normalized view as the live tree",
       %{root: root} do
    init_git_repo(root)

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => "billing.invoice",
          "statement" => "The system MUST emit an invoice on every charge.",
          "priority" => "must"
        }
      ]
    )

    write_decision(root, "billing_split", @decision)
    commit_all(root, "initial")

    live_state = root |> SpecLedEx.index(test_tags: false) |> SpecLedEx.normalize_for_state()

    assert {:ok, %{"state" => base_state, "decisions" => decisions}} =
             BaseView.build(root, "HEAD")

    assert base_state == live_state
    assert ["specled.decision.billing_split"] = Enum.map(decisions, &get_in(&1, ["meta", "id"]))
  end

  @tag spec: "specled.index.base_view_parses_base_sources"
  test "base view includes a base spec file that was deleted at head", %{root: root} do
    init_git_repo(root)

    write_subject_spec(
      root,
      "kept",
      meta: %{"id" => "kept.subject", "kind" => "module", "status" => "active"}
    )

    write_subject_spec(
      root,
      "deleted",
      meta: %{"id" => "deleted.subject", "kind" => "module", "status" => "active"}
    )

    commit_all(root, "initial")
    File.rm!(Path.join(root, ".spec/specs/deleted.spec.md"))

    assert {:ok, %{"state" => base_state}} = BaseView.build(root, "HEAD")

    subject_ids =
      base_state
      |> get_in(["index", "subjects"])
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert subject_ids == ["deleted.subject", "kept.subject"]
  end

  @tag spec: "specled.append_only.no_baseline"
  test "base without authored spec paths degrades to first-run missing", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "# Empty\n"})
    commit_all(root, "initial without spec workspace")

    assert {:missing, :first_run} = BaseView.build(root, "HEAD")
  end
end
