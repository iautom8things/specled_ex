defmodule SpecLedEx.BranchCheck.SeverityIntegrationTest do
  use SpecLedEx.Case

  alias SpecLedEx.BranchCheck
  alias SpecLedEx.Index

  @moduletag :capture_log

  describe "BranchCheck.run/3 routes severities through Severity.resolve/3" do
    @tag spec: "specled.severity.resolve_precedence"
    test "config.severities :off suppresses branch_guard_unmapped_change", %{root: root} do
      init_git_repo(root)

      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join(root, ".spec/config.yml"), """
      branch_guard:
        severities:
          branch_guard_unmapped_change: off
      """)

      File.mkdir_p!(Path.join(root, ".spec/specs"))
      write_files(root, %{"README.md" => "init\n"})
      commit_all(root, "initial")

      # A changed lib file with no covering subject → would normally emit
      # branch_guard_unmapped_change at :error. With :off in config it
      # must be suppressed entirely.
      write_files(root, %{"lib/orphan.ex" => "defmodule Orphan do\nend\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      assert Enum.all?(
               report["findings"],
               &(&1["code"] != "branch_guard_unmapped_change")
             ),
             "expected :off to suppress branch_guard_unmapped_change, got: " <>
               inspect(report["findings"])
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "config.severities can escalate branch_guard_requirement_without_test_tag to :error",
         %{root: root} do
      init_git_repo(root)

      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join(root, ".spec/config.yml"), """
      test_tags:
        enabled: true
        paths:
          - test
      branch_guard:
        severities:
          branch_guard_requirement_without_test_tag: error
      """)

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "billing.list", "statement" => "Initial one", "priority" => "must"}
        ]
      )

      commit_all(root, "initial")

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "billing.list", "statement" => "Initial one", "priority" => "must"},
          %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
        ]
      )

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      tag_findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_requirement_without_test_tag"))

      assert length(tag_findings) == 1
      assert hd(tag_findings)["severity"] == "error"
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "BranchCheck source routes all finding emissions through Severity.resolve/3" do
      # Defends against re-hardcoding severities at call sites. If a new
      # `finding(...)` call slips in that hardcodes "error"/"warning"
      # instead of going through emit/Severity.resolve, this fails.
      source = File.read!("lib/specled_ex/branch_check.ex")

      assert source =~ "alias SpecLedEx.BranchCheck.Severity",
             "BranchCheck must alias Severity"

      assert source =~ "Severity.resolve(",
             "BranchCheck must call Severity.resolve/3"

      refute source =~ ~r/defp\s+severity_from_config/,
             "severity_from_config helper must not re-implement precedence"

      refute source =~ ~r/finding\(\s*"error"\s*,\s*"branch_guard/,
             ~s(hardcoded "error" on a branch_guard finding — route through Severity.resolve/3)

      refute source =~ ~r/finding\(\s*"warning"\s*,\s*"branch_guard/,
             ~s(hardcoded "warning" on a branch_guard finding — route through Severity.resolve/3)
    end

    @tag spec: "specled.severity.off_is_absorbing"
    test "config.severities :off suppresses branch_guard_missing_decision_update", %{root: root} do
      init_git_repo(root)

      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join(root, ".spec/config.yml"), """
      branch_guard:
        severities:
          branch_guard_missing_decision_update: off
      """)

      # Two subjects, each with a lib surface
      write_files(root, %{
        "lib/a.ex" => "defmodule A do\nend\n",
        "lib/b.ex" => "defmodule B do\nend\n"
      })

      write_subject_spec(
        root,
        "a",
        meta: %{
          "id" => "a.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/a.ex"]
        }
      )

      write_subject_spec(
        root,
        "b",
        meta: %{
          "id" => "b.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/b.ex"]
        }
      )

      commit_all(root, "initial")

      # Change both lib files → cross-cutting change. Without :off this
      # would produce branch_guard_missing_decision_update; with :off
      # it's silenced.
      write_files(root, %{
        "lib/a.ex" => "defmodule A do\n  def run, do: :ok\nend\n",
        "lib/b.ex" => "defmodule B do\n  def run, do: :ok\nend\n"
      })

      # Touch both spec files so each impacted subject is also updated —
      # otherwise branch_guard_missing_subject_update fires instead.
      for name <- ["a", "b"] do
        path = Path.join(root, ".spec/specs/#{name}.spec.md")
        File.write!(path, File.read!(path) <> "\n")
      end

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      refute Enum.any?(
               report["findings"],
               &(&1["code"] == "branch_guard_missing_decision_update")
             )
    end
  end
end
