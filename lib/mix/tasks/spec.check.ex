defmodule Mix.Tasks.Spec.Check do
  use Mix.Task

  @shortdoc "Runs spec.plan and strict spec.verify"

  @impl true
  def run(args) do
    Mix.Task.run("spec.plan", args)
    Mix.Task.run("spec.verify", ["--strict" | args])

    {opts, _rest, _invalid} =
      OptionParser.parse(args, switches: [root: :string, spec_dir: :string], aliases: [r: :root])

    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    state_path = Path.expand("#{spec_dir}/state.json", root)
    state = SpecLedEx.Json.read(state_path)
    findings = state["findings"] || []

    has_errors = Enum.any?(findings, &(&1["level"] == "error"))
    has_warnings = Enum.any?(findings, &(&1["level"] == "warning"))

    if has_errors or has_warnings do
      Mix.raise("Spec check failed: #{length(findings)} finding(s)")
    end
  end
end
