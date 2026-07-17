defmodule SpecLedEx.Evidence.TreeHash do
  @moduledoc """
  Computes evidence keys from Git trees without mutating the worktree index.
  """

  @type hash :: String.t()

  @doc """
  Computes the current worktree key by mirroring `git add -A` in a temporary index.
  """
  @spec current(Path.t()) :: {:ok, hash()} | {:error, term()}
  def current(root) do
    with {:ok, index_path} <- temp_index_path(root),
         :ok <- seed_index(root, index_path),
         {:ok, _} <- git(root, ["add", "-A"], env: [{"GIT_INDEX_FILE", index_path}]),
         {:ok, tree_hash} <- git(root, ["write-tree"], env: [{"GIT_INDEX_FILE", index_path}]) do
      File.rm(index_path)
      {:ok, String.trim(tree_hash)}
    else
      {:error, reason} = error ->
        error
        |> tap(fn _ -> cleanup_temp_reason(reason) end)
    end
  end

  @doc """
  Resolves a base ref to its tree hash.
  """
  @spec base(Path.t(), String.t()) :: {:ok, hash()} | {:error, term()}
  def base(root, ref) when is_binary(ref) do
    case git(root, ["rev-parse", "--verify", "--end-of-options", "#{ref}^{tree}"]) do
      {:ok, tree_hash} -> {:ok, String.trim(tree_hash)}
      error -> error
    end
  end

  defp seed_index(root, index_path) do
    case git(root, ["rev-parse", "--verify", "--quiet", "HEAD"]) do
      {:ok, _} ->
        case git(root, ["read-tree", "HEAD"], env: [{"GIT_INDEX_FILE", index_path}]) do
          {:ok, _} -> :ok
          error -> error
        end

      {:error, _} ->
        :ok
    end
  end

  defp temp_index_path(root) do
    with {:ok, tmp_dir} <- git_path(root, "specled-tmp"),
         :ok <- File.mkdir_p(tmp_dir) do
      {:ok,
       Path.join(
         tmp_dir,
         "index-#{System.unique_integer([:positive, :monotonic])}-#{random_hex(8)}"
       )}
    end
  end

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp cleanup_temp_reason({:git, _args, _output, _status}), do: :ok
  defp cleanup_temp_reason(_reason), do: :ok

  defp git_path(root, path) do
    case git(root, ["rev-parse", "--git-path", path]) do
      {:ok, git_path} -> {:ok, Path.expand(String.trim(git_path), root)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(root, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])

    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, args, output, status}}
    end
  end
end
