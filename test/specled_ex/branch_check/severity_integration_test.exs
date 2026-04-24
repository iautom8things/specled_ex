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

  describe "BranchCheck.run/3 routes guardrails.severities through Severity.resolve/3" do
    @tag spec: "specled.config.guardrails_severities"
    @tag spec: "specled.severity.resolve_precedence"
    test "guardrails.severities downgrades append_only/requirement_deleted to :warning",
         %{root: root} do
      init_git_repo(root)

      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join(root, ".spec/config.yml"), """
      guardrails:
        severities:
          append_only/requirement_deleted: warning
      """)

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

      commit_all(root, "remove billing.invoice")

      new_index = SpecLedEx.index(root)
      report = SpecLedEx.BranchCheck.run(new_index, root, base: "HEAD~1")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "append_only/requirement_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "warning"
    end

    @tag spec: "specled.config.guardrails_severities"
    @tag spec: "specled.severity.off_is_absorbing"
    test "guardrails.severities :off suppresses overlap/duplicate_covers", %{root: root} do
      init_git_repo(root)

      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join(root, ".spec/config.yml"), """
      guardrails:
        severities:
          overlap/duplicate_covers: off
      """)

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
        ],
        scenarios: [
          %{
            "id" => "billing.scenario.a",
            "covers" => ["billing.invoice"]
          },
          %{
            "id" => "billing.scenario.b",
            "covers" => ["billing.invoice"]
          }
        ]
      )

      commit_all(root, "initial with duplicate covers")

      index = SpecLedEx.index(root)
      report = SpecLedEx.BranchCheck.run(index, root, base: "HEAD")

      refute Enum.any?(report["findings"], &(&1["code"] == "overlap/duplicate_covers"))
    end

    @tag spec: "specled.config.guardrails_severities"
    @tag spec: "specled.severity.resolve_precedence"
    test "guardrails.severities namespace is independent of branch_guard.severities",
         %{root: root} do
      init_git_repo(root)

      File.mkdir_p!(Path.join(root, ".spec"))

      # branch_guard.severities sets an off for branch_guard_unmapped_change,
      # but that must NOT leak into guardrails' namespace — append_only codes
      # keep their per-code defaults.
      File.write!(Path.join(root, ".spec/config.yml"), """
      branch_guard:
        severities:
          branch_guard_unmapped_change: off
      """)

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

      commit_all(root, "remove billing.invoice")

      new_index = SpecLedEx.index(root)
      report = SpecLedEx.BranchCheck.run(new_index, root, base: "HEAD~1")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "append_only/requirement_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "error"
    end
  end

  describe "@per_code_defaults covers every finding code emitted by this project" do
    # Table-driven: one row per finding code with its baked-in default severity.
    # Every entry in this table must appear in BranchCheck's @per_code_defaults
    # map so that `BranchCheck.Severity.resolve/3` can honor config and trailer
    # overrides without needing to re-derive the default at each emission site.
    # Source-level check keeps this independent of runtime wiring.

    branch_guard_codes = [
      {"branch_guard_unmapped_change", :error},
      {"branch_guard_missing_subject_update", :error},
      {"branch_guard_missing_decision_update", :error},
      {"branch_guard_requirement_without_test_tag", :warning}
    ]

    append_only_codes = [
      {"append_only/requirement_deleted", :error},
      {"append_only/must_downgraded", :error},
      {"append_only/scenario_regression", :error},
      {"append_only/negative_removed", :error},
      {"append_only/disabled_without_reason", :warning},
      {"append_only/no_baseline", :info},
      {"append_only/adr_affects_widened", :error},
      {"append_only/same_pr_self_authorization", :warning},
      {"append_only/missing_change_type", :warning},
      {"append_only/decision_deleted", :error}
    ]

    overlap_codes = [
      {"overlap/duplicate_covers", :error},
      {"overlap/must_stem_collision", :error}
    ]

    for {code, expected} <- branch_guard_codes ++ append_only_codes ++ overlap_codes do
      @code code
      @expected expected

      @tag spec: "specled.severity.resolve_precedence"
      test "@per_code_defaults maps #{code} to :#{expected}" do
        source = File.read!("lib/specled_ex/branch_check.ex")
        severity = Atom.to_string(@expected)

        pattern =
          ~r/"#{Regex.escape(@code)}"\s*=>\s*:#{severity}/

        assert Regex.match?(pattern, source),
               "expected BranchCheck @per_code_defaults to map #{inspect(@code)} => :#{severity}"
      end
    end
  end
end
