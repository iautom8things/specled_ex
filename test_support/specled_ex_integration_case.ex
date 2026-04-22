defmodule SpecLedEx.IntegrationCase do
  @moduledoc """
  Case template for integration tests that compile a fixture Mix project.

  Fixtures live under `test/fixtures/<name>/`. `compile_fixture/1` runs
  `mix compile` inside the fixture (isolated from the host project's
  `_build/`) and returns the build path so tests can read compile manifests.

  Tagged `:integration` by default — only runs with `mix test --include integration`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import SpecLedEx.IntegrationCase
    end
  end

  @doc """
  Compiles the fixture at `test/fixtures/<name>/` and returns `{root, build_path}`.

  Leaves the fixture's `_build/` in place across runs (Mix caches appropriately).
  """
  @spec compile_fixture(String.t()) :: {Path.t(), Path.t()}
  def compile_fixture(name) do
    root = Path.expand(Path.join(["test/fixtures", name]))

    unless File.dir?(root) do
      raise "fixture directory not found: #{root}"
    end

    {output, status} =
      System.cmd("mix", ["compile"],
        cd: root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      raise "fixture compile failed for #{name}:\n#{output}"
    end

    build_path = Path.join(root, "_build")
    {root, build_path}
  end

  @doc "Returns the manifest path for a fixture's compiled output."
  @spec manifest_path(Path.t(), atom(), atom()) :: Path.t()
  def manifest_path(build_path, env \\ :test, app) do
    Path.join([
      build_path,
      Atom.to_string(env),
      "lib",
      Atom.to_string(app),
      ".mix",
      "compile.elixir"
    ])
  end
end
