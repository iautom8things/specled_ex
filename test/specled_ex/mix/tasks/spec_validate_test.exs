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

defmodule Mix.Tasks.Spec.ValidateCommandTimeoutTest do
  use SpecLedEx.Case

  @moduletag :capture_log

  describe "--command-timeout-ms precedence" do
    @tag spec: "specled.verify.command_timeout_cli_precedence"
    test "flag beats config value", %{root: root} do
      write_timeout_config(root, 1)
      marker = write_slow_command_spec(root, "validate_cli_timeout")

      Mix.Tasks.Spec.Validate.run([
        "--root",
        root,
        "--run-commands",
        "--strict",
        "--command-timeout-ms",
        "5000"
      ])

      assert read_state(root)["summary"]["findings"] == 0
      assert File.read!(Path.join(root, marker)) == "done"
    end

    @tag spec: "specled.verify.command_timeout_cli_precedence"
    test "absent flag falls back to config value", %{root: root} do
      write_timeout_config(root, 1)
      write_slow_command_spec(root, "validate_config_timeout")

      assert_raise Mix.Error, ~r/Spec validate failed: 1 finding/, fn ->
        Mix.Tasks.Spec.Validate.run(["--root", root, "--run-commands", "--strict"])
      end

      assert [%{"code" => "verification_command_failed"}] = read_state(root)["findings"]
    end

    @tag spec: "specled.verify.command_timeout_cli_precedence"
    test "absent flag and config fall back to verifier default", %{root: root} do
      marker = write_slow_command_spec(root, "validate_default_timeout")

      Mix.Tasks.Spec.Validate.run(["--root", root, "--run-commands", "--strict"])

      assert read_state(root)["summary"]["findings"] == 0
      assert File.read!(Path.join(root, marker)) == "done"
    end
  end

  defp write_timeout_config(root, timeout_ms) do
    write_files(root, %{
      ".spec/config.yml" => "verification:\n  command_timeout_ms: #{timeout_ms}\n"
    })
  end

  defp write_slow_command_spec(root, name) do
    marker = "#{name}.txt"
    requirement_id = "#{name}.requirement"

    write_subject_spec(
      root,
      name,
      meta: %{"id" => "#{name}.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => requirement_id,
          "statement" =>
            "Command timeout precedence remains observable through a deliberately slow verification command."
        }
      ],
      verification: [
        %{
          "kind" => "command",
          "target" => "sleep 0.05; printf done > #{marker}",
          "covers" => [requirement_id],
          "execute" => true
        }
      ]
    )

    marker
  end
end
