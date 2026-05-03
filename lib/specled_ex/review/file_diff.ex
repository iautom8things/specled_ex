defmodule SpecLedEx.Review.FileDiff do
  @moduledoc false

  @type line_kind :: :file_header | :hunk_header | :add | :del | :ctx
  @type line :: {line_kind, String.t()}

  @doc """
  Returns a map of `path => [line]` for the given paths, computed by
  diffing `base` against the working tree (which includes committed and
  uncommitted changes). Untracked files are surfaced as full additions.

  An empty `paths` list returns `%{}` without invoking git.
  """
  @spec for_files(String.t(), String.t(), [String.t()]) :: %{String.t() => [line]}
  def for_files(_root, _base, []), do: %{}

  def for_files(root, base, paths) when is_list(paths) do
    {tracked, untracked} = partition_tracked(root, paths)

    tracked_diffs =
      case tracked do
        [] -> %{}
        list -> list |> run_diff(root, base) |> parse_unified_diff()
      end

    untracked_diffs = Map.new(untracked, fn path -> {path, untracked_as_addition(root, path)} end)

    Map.merge(tracked_diffs, untracked_diffs)
  end

  defp run_diff(paths, root, base) do
    args = ["-C", root, "diff", "--no-color", base, "--"] ++ paths
    {output, _exit_code} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp partition_tracked(root, paths) do
    Enum.split_with(paths, fn path -> tracked?(root, path) end)
  end

  defp tracked?(root, path) do
    {_out, status} =
      System.cmd("git", ["-C", root, "ls-files", "--error-unmatch", path], stderr_to_stdout: true)

    status == 0
  end

  defp untracked_as_addition(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, content} ->
        header = [{:file_header, "diff --git a/#{path} b/#{path}"}, {:file_header, "new file"}]

        body =
          content
          |> String.split("\n")
          |> Enum.map(&{:add, "+" <> &1})

        header ++ body

      {:error, _} ->
        []
    end
  end

  defp parse_unified_diff(""), do: %{}

  defp parse_unified_diff(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({nil, %{}, []}, &consume_line/2)
    |> finalize()
  end

  defp consume_line("diff --git a/" <> rest = line, {current, acc, lines}) do
    acc = stash_current(current, acc, lines)
    new_path = rest |> String.split(" ", parts: 2) |> List.first()
    {new_path, acc, [{:file_header, line}]}
  end

  defp consume_line("@@ " <> _ = line, {current, acc, lines}) do
    {current, acc, [{:hunk_header, line} | lines]}
  end

  defp consume_line("+++" <> _ = line, {current, acc, lines}),
    do: {current, acc, [{:file_header, line} | lines]}

  defp consume_line("---" <> _ = line, {current, acc, lines}),
    do: {current, acc, [{:file_header, line} | lines]}

  defp consume_line("+" <> _ = line, {current, acc, lines}),
    do: {current, acc, [{:add, line} | lines]}

  defp consume_line("-" <> _ = line, {current, acc, lines}),
    do: {current, acc, [{:del, line} | lines]}

  defp consume_line("\\ " <> _ = line, {current, acc, lines}),
    do: {current, acc, [{:ctx, line} | lines]}

  defp consume_line(line, {current, acc, lines}),
    do: {current, acc, [{:ctx, line} | lines]}

  defp finalize({current, acc, lines}), do: stash_current(current, acc, lines)

  defp stash_current(nil, acc, _lines), do: acc
  defp stash_current(path, acc, lines), do: Map.put(acc, path, Enum.reverse(lines))
end
