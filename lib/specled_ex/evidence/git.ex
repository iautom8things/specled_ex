defmodule SpecLedEx.Evidence.Git do
  @moduledoc """
  Shared Git plumbing helpers for the evidence store, sync, and tree-hash
  modules: subprocess execution, unique temp-path allocation under the
  repository's `.git/specled-tmp` directory, and random hex generation for
  uniquifying temp filenames.
  """

  @tmp_dir_name "specled-tmp"

  @doc """
  Runs a git plumbing command against `root`, returning `{:ok, output}` or
  `{:error, {:git, args, output, status}}` on non-zero exit.
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, {:git, [String.t()], String.t(), non_neg_integer()}}
  def run(root, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])

    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, args, output, status}}
    end
  end

  @doc """
  Allocates a unique path under the repository's `.git/specled-tmp`
  directory, prefixed with `label`, creating the directory if needed.
  """
  @spec temp_path(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def temp_path(root, label) do
    with {:ok, directory} <- tmp_dir(root) do
      {:ok,
       Path.join(
         directory,
         "#{label}-#{System.unique_integer([:positive, :monotonic])}-#{random_hex(8)}"
       )}
    end
  end

  @doc """
  Generates a random lowercase hex string of `bytes` bytes.
  """
  @spec random_hex(pos_integer()) :: String.t()
  def random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp tmp_dir(root) do
    with {:ok, git_path} <- run(root, ["rev-parse", "--git-path", @tmp_dir_name]) do
      directory = Path.expand(String.trim(git_path), root)

      with :ok <- File.mkdir_p(directory) do
        {:ok, directory}
      end
    end
  end
end
