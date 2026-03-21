defmodule Mix.Tasks.Spec.Diffcheck do
  use Mix.Task

  @shortdoc "Checks Git diff co-changes against current-truth subjects and ADRs"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(
        args,
        strict: [root: :string, spec_dir: :string, base: :string],
        aliases: [r: :root]
      )

    validate_args!(rest, invalid)

    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    index = SpecLedEx.build_index(root, spec_dir: spec_dir, authored_dir: authored_dir)
    report = SpecLedEx.diffcheck(index, root, base: opts[:base])

    Mix.shell().info(
      "spec.diffcheck base=#{report["base"]} changed_files=#{report["summary"]["changed_files"]} findings=#{report["summary"]["findings"]}"
    )

    Enum.each(report["findings"], fn finding ->
      severity = String.upcase(finding["severity"] || "warning")
      file = finding["file"] || "-"
      Mix.shell().info("[#{severity}] #{finding["code"]} #{file} :: #{finding["message"]}")
    end)

    guidance = report["guidance"] || %{}
    impacted_subjects = guidance["impacted_subject_ids"] || []
    uncovered_policy_files = guidance["uncovered_policy_files"] || []

    Mix.shell().info("guidance change_type=#{guidance["change_type"] || "non_contract_or_meta"}")
    Mix.shell().info("guidance impacted_subjects=#{Enum.join(impacted_subjects, ", ")}")
    Mix.shell().info("guidance uncovered_policy_files=#{Enum.join(uncovered_policy_files, ", ")}")
    Mix.shell().info("guidance next=#{guidance["suggested_command"]}")

    if report["status"] == "fail" do
      Mix.raise("Spec diffcheck failed: #{length(report["findings"] || [])} finding(s)")
    end
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    Mix.raise("Invalid arguments for spec.diffcheck: #{details}")
  end
end
