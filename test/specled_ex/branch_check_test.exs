defmodule SpecLedEx.BranchCheckTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.branch_guard.new_requirement_tag_warning", "specled.branch_guard.tag_findings_respect_enforcement"]

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
      ],
      verification: [
        %{
          "kind" => "tagged_tests",
          "covers" => ["billing.list", "billing.invoice"],
          "execute" => true
        }
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

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "does not emit finding when the new must requirement is covered only by a non-tagged_tests verification",
       %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
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
        %{"id" => "billing.docs_ready", "statement" => "Docs ready", "priority" => "must"}
      ],
      verification: [
        %{
          "kind" => "source_file",
          "target" => ".spec/specs/billing.spec.md",
          "covers" => ["billing.docs_ready"]
        }
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
      ],
      verification: [
        %{
          "kind" => "tagged_tests",
          "covers" => ["billing.list", "billing.invoice"],
          "execute" => true
        }
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

  describe "append_only integration" do
    @tag spec: "specled.append_only.requirement_deleted"
    test "AppendOnly finding flows into BranchCheck.run via Severity.resolve/3", %{root: root} do
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

      # Commit state.json alongside the spec so there is a prior baseline.
      index = SpecLedEx.index(root)
      SpecLedEx.write_state(index, nil, root)
      commit_all(root, "initial: add billing subject + state.json")

      # Now delete the requirement. No authorizing ADR → AppendOnly must fire.
      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: []
      )

      commit_all(root, "remove billing.invoice")

      new_index = SpecLedEx.index(root)
      report = BranchCheck.run(new_index, root, base: "HEAD~1")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "append_only/requirement_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "error"
      assert finding["entity_id"] == "billing.invoice"
      assert finding["message"] =~ "billing.invoice"
      assert finding["message"] =~ "fix:"
      assert report["status"] == "fail"
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "Spec-Drift trailer downgrades an append_only finding to :info", %{root: root} do
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

      index = SpecLedEx.index(root)
      SpecLedEx.write_state(index, nil, root)
      commit_all(root, "initial")

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: []
      )

      commit_all(root, """
      Retire billing.invoice

      Spec-Drift: append_only/requirement_deleted=info
      """)

      new_index = SpecLedEx.index(root)
      report = BranchCheck.run(new_index, root, base: "HEAD~1")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "append_only/requirement_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "info"
    end

    @tag spec: "specled.append_only.no_baseline"
    test "missing state.json at base yields append_only/no_baseline at :info", %{root: root} do
      init_git_repo(root)

      # First commit has a spec but no state.json — simulates the bootstrap
      # case (or a base ref predating spec-guardrails adoption).
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

      commit_all(root, "initial spec, no state.json")

      # Second commit adds state.json so head has one. Prior baseline still
      # missing at HEAD~1 → no_baseline fires on this base.
      index = SpecLedEx.index(root)
      SpecLedEx.write_state(index, nil, root)
      commit_all(root, "add state.json")

      report = BranchCheck.run(index, root, base: "HEAD~1")

      findings = Enum.filter(report["findings"], &(&1["code"] == "append_only/no_baseline"))

      assert [finding] = findings
      assert finding["severity"] == "info"
      assert finding["message"] =~ "first-run"
    end
  end

  describe "--base validation" do
    test "--base pointing at a non-existent ref raises a clean ArgumentError", %{root: root} do
      init_git_repo(root)

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"}
      )

      commit_all(root, "initial")

      index = SpecLedEx.index(root)

      assert_raise ArgumentError, ~r/does not resolve to a commit/, fn ->
        BranchCheck.run(index, root, base: "definitely-not-a-real-ref")
      end
    end
  end

  describe "self-integration" do
    @tag :integration
    test "git show HEAD:.spec/state.json parses against specled_ex's own repo" do
      root = File.cwd!()

      {output, exit_code} =
        System.cmd("git", ["-C", root, "show", "HEAD:.spec/state.json"], stderr_to_stdout: true)

      assert exit_code == 0, "git show HEAD:.spec/state.json failed: #{output}"
      assert {:ok, state} = Jason.decode(output)
      assert is_map(state)
      assert is_map(state["index"])
    end
  end
end
