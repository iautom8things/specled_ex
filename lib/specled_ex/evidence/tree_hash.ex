defmodule SpecLedEx.Evidence.TreeHash do
  @moduledoc """
  Computes evidence keys from Git trees without mutating the worktree index.
  """

  alias SpecLedEx.Evidence.Git

  @type hash :: String.t()

  @doc """
  Computes the current worktree key by mirroring `git add -A` in a temporary index.
  """
  @spec current(Path.t()) :: {:ok, hash()} | {:error, term()}
  def current(root) do
    with {:ok, index_path} <- Git.temp_path(root, "index"),
         :ok <- seed_index(root, index_path),
         {:ok, _} <- Git.run(root, ["add", "-A"], env: [{"GIT_INDEX_FILE", index_path}]),
         {:ok, tree_hash} <- Git.run(root, ["write-tree"], env: [{"GIT_INDEX_FILE", index_path}]) do
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
    case Git.run(root, ["rev-parse", "--verify", "--end-of-options", "#{ref}^{tree}"]) do
      {:ok, tree_hash} -> {:ok, String.trim(tree_hash)}
      error -> error
    end
  end

  defp seed_index(root, index_path) do
    case Git.run(root, ["rev-parse", "--verify", "--quiet", "HEAD"]) do
      {:ok, _} ->
        case Git.run(root, ["read-tree", "HEAD"], env: [{"GIT_INDEX_FILE", index_path}]) do
          {:ok, _} -> :ok
          error -> error
        end

      {:error, _} ->
        :ok
    end
  end

  defp cleanup_temp_reason({:git, _args, _output, _status}), do: :ok
  defp cleanup_temp_reason(_reason), do: :ok
end
