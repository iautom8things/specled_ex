defmodule Mix.Tasks.SpecStatusTaskTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.status.coverage_summary", "specled.status.decision_index", "specled.status.frontier_summary", "specled.tasks.check_strict_gate", "specled.tasks.decision_new_scaffold", "specled.tasks.index_writes_state", "specled.tasks.init_local_skill", "specled.tasks.init_scaffold", "specled.tasks.next_guidance", "specled.tasks.no_app_start", "specled.tasks.prime_context", "specled.tasks.prime_json", "specled.tasks.status_summary", "specled.tasks.validate_exit_status", "specled.tasks.validate_findings"]
  test "spec.status executes commands by default and allows opting out", %{root: root} do
    write_subject_spec(
      root,
      "report_commands",
      meta: %{"id" => "report.commands", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "report.commands.requirement", "statement" => "Covered by command"}
      ],
      verification: [
        %{
          "kind" => "command",
          "target" => "printf reported >> reported.txt",
          "covers" => ["report.commands.requirement"],
          "execute" => true
        }
      ]
    )

    Mix.Tasks.Spec.Status.run(["--root", root])

    assert File.read!(Path.join(root, "reported.txt")) == "reported"

    File.rm!(Path.join(root, "reported.txt"))
    reenable_tasks(["spec.status"])

    Mix.Tasks.Spec.Status.run(["--root", root, "--no-run-commands"])

    refute File.exists?(Path.join(root, "reported.txt"))
  end
end
