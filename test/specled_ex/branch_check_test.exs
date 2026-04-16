defmodule SpecLedEx.BranchCheckTest do
  use SpecLedEx.Case

  alias SpecLedEx.{BranchCheck, Index}

  @moduletag :capture_log

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "emits finding when a new must requirement lacks a backing @tag spec", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
        enforcement: warning
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    findings =
      Enum.filter(report["findings"], &(&1["code"] == "branch_guard_requirement_without_test_tag"))

    assert length(findings) == 1
    assert hd(findings)["severity"] == "warning"
    assert hd(findings)["message"] =~ "billing.invoice"
    assert hd(findings)["file"] == ".spec/specs/billing.spec.md"
  end

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "does not emit finding when the new must requirement is already tagged", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
      """,
      "test/billing_test.exs" => """
      defmodule BillingTest do
        use ExUnit.Case

        @tag spec: "billing.invoice"
        test "covers billing.invoice" do
          assert true
        end
      end
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    refute Enum.any?(
             report["findings"],
             &(&1["code"] == "branch_guard_requirement_without_test_tag")
           )
  end

  @tag spec: "specled.branch_guard.tag_findings_respect_enforcement"
  test "promotes finding severity to error under enforcement=error", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
        enforcement: error
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    findings =
      Enum.filter(report["findings"], &(&1["code"] == "branch_guard_requirement_without_test_tag"))

    assert length(findings) == 1
    assert hd(findings)["severity"] == "error"
    assert report["status"] == "fail"
  end

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "emits no tag findings when the index has no test_tags key", %{root: root} do
    init_git_repo(root)

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ]
    )

    index = Index.build(root)
    refute Map.has_key?(index, "test_tags")

    report = BranchCheck.run(index, root, base: "HEAD")

    refute Enum.any?(
             report["findings"],
             &(&1["code"] == "branch_guard_requirement_without_test_tag")
           )
  end
end
