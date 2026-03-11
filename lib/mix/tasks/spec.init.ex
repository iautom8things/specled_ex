defmodule Mix.Tasks.Spec.Init do
  use Mix.Task

  @shortdoc "Scaffolds a canonical .spec/ workspace"
  @templates [
    {"README.md.eex", "README.md"},
    {"specs/spec_system.spec.md.eex", "specs/spec_system.spec.md"},
    {"specs/package.spec.md.eex", "specs/package.spec.md"}
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [root: :string, force: :boolean],
        aliases: [r: :root, f: :force]
      )

    validate_args!(rest, invalid)

    root = opts[:root] || File.cwd!()
    force? = opts[:force] || false
    spec_dir = Path.join(root, ".spec")
    specs_dir = Path.join(spec_dir, "specs")

    File.mkdir_p!(spec_dir)
    File.mkdir_p!(specs_dir)

    Enum.each(@templates, fn {source, destination} ->
      write_template(
        Path.join(spec_dir, destination),
        read_template!(source),
        force?
      )
    end)

    Mix.shell().info("spec.init scaffolded #{spec_dir}")
  end

  defp write_template(path, content, force?) do
    cond do
      force? ->
        File.write!(path, content)
        Mix.shell().info("wrote #{path}")

      File.exists?(path) ->
        Mix.shell().info("kept #{path}")

      true ->
        File.write!(path, content)
        Mix.shell().info("wrote #{path}")
    end
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    Mix.raise("Invalid arguments for spec.init: #{details}")
  end

  defp read_template!(relative_path) do
    relative_path
    |> template_path()
    |> EEx.eval_file([])
  end

  defp template_path(relative_path) do
    :spec_led_ex
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("spec_init")
    |> Path.join(relative_path)
  end
end
