defmodule SpecLedEx.BaseView do
  @moduledoc false

  alias SpecLedEx.Index

  @doc """
  Builds a parsed `.spec` view for `base` using the current parser.

  The base tree is enumerated from Git, materialized into an isolated temporary
  workspace, parsed through `SpecLedEx.Index.build/2`, normalized for state, and
  then removed before returning.
  """
  @spec build(Path.t(), binary(), keyword()) :: {:ok, map()} | {:missing, atom()}
  def build(root, base, opts \\ []) when is_binary(root) and is_binary(base) do
    spec_dir = opts[:spec_dir] || detect_spec_dir(root)
    authored_dir = opts[:authored_dir] || detect_authored_dir(root, spec_dir)
    decision_dir = opts[:decision_dir] || SpecLedEx.detect_decision_dir(root, spec_dir)

    case list_base_paths(root, base, authored_dir, decision_dir) do
      {:ok, []} ->
        {:missing, :first_run}

      {:ok, paths} ->
        with_temp_root(fn temp_root ->
          with :ok <- seed_workspace_dirs(temp_root, authored_dir, decision_dir),
               :ok <- materialize_paths(root, base, temp_root, paths) do
            index =
              Index.build(temp_root,
                spec_dir: spec_dir,
                authored_dir: authored_dir,
                decision_dir: decision_dir,
                test_tags: false
              )

            {:ok,
             %{
               "state" => SpecLedEx.normalize_for_state(index),
               "decisions" => Map.get(index, "decisions", [])
             }}
          end
        end)

      {:error, output} ->
        {:missing, classify_missing(root, output)}
    end
  end

  defp detect_spec_dir(root) do
    if File.dir?(Path.join(root, ".spec")) do
      SpecLedEx.detect_spec_dir(root)
    else
      ".spec"
    end
  end

  defp detect_authored_dir(root, spec_dir) do
    authored_dir = Path.join(spec_dir, "specs")

    if File.dir?(Path.join(root, authored_dir)) do
      SpecLedEx.detect_authored_dir(root, spec_dir)
    else
      authored_dir
    end
  end

  defp list_base_paths(root, base, authored_dir, decision_dir) do
    {output, exit_code} =
      System.cmd(
        "git",
        ["-C", root, "ls-tree", "-r", "--name-only", base, "--", authored_dir, decision_dir],
        stderr_to_stdout: true
      )

    if exit_code == 0 do
      paths =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&base_spec_path?(&1, authored_dir, decision_dir))
        |> Enum.sort()

      {:ok, paths}
    else
      {:error, output}
    end
  end

  defp base_spec_path?(path, authored_dir, decision_dir) do
    subject_spec?(path, authored_dir) or decision_file?(path, decision_dir)
  end

  defp subject_spec?(path, authored_dir) do
    String.starts_with?(path, authored_dir <> "/") and String.ends_with?(path, ".spec.md")
  end

  defp decision_file?(path, decision_dir) do
    String.starts_with?(path, decision_dir <> "/") and String.ends_with?(path, ".md")
  end

  defp seed_workspace_dirs(temp_root, authored_dir, decision_dir) do
    File.mkdir_p!(Path.join(temp_root, authored_dir))
    File.mkdir_p!(Path.join(temp_root, decision_dir))
    :ok
  end

  defp materialize_paths(root, base, temp_root, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case git_show(root, base, path) do
        {:ok, blob} ->
          destination = Path.join(temp_root, path)
          File.mkdir_p!(Path.dirname(destination))
          File.write!(destination, blob)
          {:cont, :ok}

        {:error, output} ->
          {:halt, {:missing, classify_missing(root, output)}}
      end
    end)
  end

  defp git_show(root, base, path) do
    {output, exit_code} =
      System.cmd("git", ["-C", root, "show", "#{base}:#{path}"], stderr_to_stdout: true)

    if exit_code == 0, do: {:ok, output}, else: {:error, output}
  end

  defp with_temp_root(fun) do
    temp_root =
      System.tmp_dir!()
      |> Path.join("specled_base_view_#{System.unique_integer([:positive, :monotonic])}")

    File.rm_rf!(temp_root)
    File.mkdir_p!(temp_root)

    try do
      fun.(temp_root)
    after
      File.rm_rf!(temp_root)
    end
  end

  defp classify_missing(root, output) do
    if SpecLedEx.BranchCheck.shallow_clone?(root) do
      :shallow_clone
    else
      SpecLedEx.BranchCheck.classify_load_error(output)
    end
  end
end
