defmodule Mix.Tasks.Spec.Plan do
  use Mix.Task

  @shortdoc "Builds plan index and writes .spec/state.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(
        args,
        switches: [root: :string, output: :string, spec_dir: :string],
        aliases: [r: :root, o: :output]
      )

    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    output = opts[:output] || "#{spec_dir}/state.json"

    index = SpecLedEx.build_index(root, spec_dir: spec_dir, authored_dir: authored_dir)
    path = SpecLedEx.write_state(index, nil, root, output)

    Mix.shell().info("spec.plan wrote #{path}")

    Mix.shell().info(
      "authored_dir=#{index["authored_dir"]} subjects=#{index["summary"]["subjects"]} requirements=#{index["summary"]["requirements"]}"
    )
  end
end
