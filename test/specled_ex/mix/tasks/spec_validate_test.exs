defmodule Mix.Tasks.Spec.Validate.RealizedByDedupTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.realized_by.redundant_dup_warning",
               "specled.realized_by.dedup_check_shared_seam"
             ]

  @moduletag :capture_log

  describe "mix spec.validate end-to-end with cross-tier dup" do
    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "emits a realized_by_redundant_dup warning for a subject duplicating an MFA across tiers",
         %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      init_git_repo(root)

      write_subject_spec(
        root,
        "dup_subject",
        meta: %{
          "id" => "dup.subject",
          "kind" => "module",
          "status" => "active",
          "realized_by" => %{
            "api_boundary" => ["Mod.a/1"],
            "implementation" => ["Mod.a/1"]
          }
        },
        requirements: [
          %{
            "id" => "dup.subject.req",
            "priority" => "must",
            "statement" =>
              "This requirement is intentionally long enough to satisfy the prose-rot check."
          }
        ],
        verification: [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["dup.subject.req"]
          }
        ]
      )

      Mix.Tasks.Spec.Validate.run(["--root", root])

      state = read_state(root)
      findings = state["findings"] || []

      dup_findings =
        Enum.filter(findings, &(&1["code"] == "realized_by_redundant_dup"))

      assert [finding] = dup_findings
      assert finding["level"] == "warning"
      assert finding["entity_id"] == "dup.subject"
      assert finding["message"] =~ "Mod.a/1"
      assert finding["message"] =~ "mix spec.dedup_realized_by"
      # MFA-form variant
      assert finding["message"] =~ "strict subset"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "bare-module duplications get the head-union/full-union message variant",
         %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      init_git_repo(root)

      write_subject_spec(
        root,
        "bare_dup_subject",
        meta: %{
          "id" => "bare.subject",
          "kind" => "module",
          "status" => "active",
          "realized_by" => %{
            "api_boundary" => ["SpecLedEx.Coverage"],
            "implementation" => ["SpecLedEx.Coverage"]
          }
        },
        requirements: [
          %{
            "id" => "bare.subject.req",
            "priority" => "must",
            "statement" =>
              "This requirement is intentionally long enough to satisfy the prose-rot check."
          }
        ],
        verification: [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["bare.subject.req"]
          }
        ]
      )

      Mix.Tasks.Spec.Validate.run(["--root", root])

      state = read_state(root)
      findings = state["findings"] || []

      [finding] = Enum.filter(findings, &(&1["code"] == "realized_by_redundant_dup"))

      assert finding["level"] == "warning"
      assert finding["entity_id"] == "bare.subject"
      assert finding["message"] =~ "SpecLedEx.Coverage"
      assert finding["message"] =~ "head-union"
      assert finding["message"] =~ "full-union"
      refute finding["message"] =~ "strict subset"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "no realized_by_redundant_dup finding when api_boundary and implementation differ",
         %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      init_git_repo(root)

      write_subject_spec(
        root,
        "no_dup_subject",
        meta: %{
          "id" => "no_dup.subject",
          "kind" => "module",
          "status" => "active",
          "realized_by" => %{
            "api_boundary" => ["Mod.a/1"],
            "implementation" => ["Mod.b/2"]
          }
        },
        requirements: [
          %{
            "id" => "no_dup.subject.req",
            "priority" => "must",
            "statement" =>
              "This requirement is intentionally long enough to satisfy the prose-rot check."
          }
        ],
        verification: [
          %{
            "kind" => "tagged_tests",
            "execute" => true,
            "covers" => ["no_dup.subject.req"]
          }
        ]
      )

      Mix.Tasks.Spec.Validate.run(["--root", root])

      state = read_state(root)
      findings = state["findings"] || []

      refute Enum.any?(findings, &(&1["code"] == "realized_by_redundant_dup"))
    end
  end
end
