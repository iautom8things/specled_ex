defmodule Mix.Tasks.Spec.Evidence.InstallHook do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Installs the spec evidence pre-push hook"
  @moduledoc """
  Installs specled's static pre-push shim.

  The shim runs `mix spec.sync --best-effort` and always exits 0. If a
  repository already has `.git/hooks/pre-push`, this task leaves it untouched
  and prints the snippet to append manually.
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string], aliases: [r: :root])

    SpecLedEx.TaskArgs.validate!("spec.evidence.install_hook", rest, invalid)

    root = opts[:root] || File.cwd!()
    hook_path = git_path!(root, "hooks/pre-push")
    shim = shim_bytes()

    if File.exists?(hook_path) do
      Mix.shell().info("pre-push hook already exists; leaving it unchanged")
      Mix.shell().info("Append this snippet to #{hook_path} if you want spec evidence sync:")
      Mix.shell().info(snippet(shim))
    else
      File.mkdir_p!(Path.dirname(hook_path))
      File.write!(hook_path, shim)
      File.chmod!(hook_path, 0o755)
      Mix.shell().info("spec.evidence.install_hook wrote #{hook_path}")
    end
  end

  @doc false
  def shim_bytes do
    :spec_led_ex
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("hooks/pre-push")
    |> File.read!()
  end

  @doc false
  def snippet(shim \\ shim_bytes()) do
    [
      "",
      "# specled evidence sync",
      String.trim_trailing(shim)
    ]
    |> Enum.join("\n")
  end

  defp git_path!(root, path) do
    {output, status} = System.cmd("git", ["-C", root, "rev-parse", "--git-path", path])

    if status == 0 do
      Path.expand(String.trim(output), root)
    else
      Mix.raise("Unable to resolve git path #{path} under #{root}")
    end
  end
end
