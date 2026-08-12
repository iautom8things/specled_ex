defmodule SpecLedEx.RealizationCommentPointerLintTest do
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.decisions.adr_reference_discipline"]

  @minimum_block_lines 8
  @corpus_glob "lib/specled_ex/realization/*.ex"
  @corpus_path_pattern ~r{\Alib/specled_ex/realization/[^/]+\.ex\z}
  @adr_pointer_pattern ~r{(?:^|\s)`?(?<id>specled\.decision\.[a-z0-9_]+)`?\.?\z}
  @allow_marker_pattern ~r{\Aspec-lint:allow-long-comment=\S(?:.*\S)?\z}
  @separator_pattern ~r/\A-{3,}\z/

  test "every long realization comment block ends in an ADR pointer or narrow exemption" do
    files = corpus_files()

    assert length(files) == 12,
           "expected the 12-file realization corpus, found #{length(files)} files"

    assert Enum.all?(files, &realization_file?/1)

    violations = Enum.flat_map(files, &violations_in_file/1)

    assert violations == [],
           "Long realization comments must end in an ADR pointer or narrow exemption:\n" <>
             Enum.join(violations, "\n")
  end

  test "eight lines is the enforced boundary and seven lines is ignored" do
    seven_lines = List.duplicate("# implementation detail", 7)
    eight_lines = List.duplicate("# implementation detail", 8)

    assert violations_for_lines(seven_lines, realization_path()) == []
    assert length(violations_for_lines(eight_lines, realization_path())) == 1
  end

  test "a terminal existing ADR id satisfies the discipline" do
    lines =
      List.duplicate("# architectural context", 7) ++
        ["# See `specled.decision.deterministic_hashing`."]

    assert violations_for_lines(lines, realization_path()) == []
  end

  test "a terminal unknown ADR id does not satisfy the discipline" do
    lines =
      List.duplicate("# architectural context", 7) ++
        ["# See `specled.decision.this_adr_does_not_exist`."]

    assert length(violations_for_lines(lines, realization_path())) == 1
  end

  test "an ADR id before the final line does not satisfy the discipline" do
    lines =
      List.duplicate("# architectural context", 6) ++
        ["# See `specled.decision.deterministic_hashing`.", "# additional restatement"]

    assert length(violations_for_lines(lines, realization_path())) == 1
  end

  test "hyphen separators do not exempt long prose and do not count toward the threshold" do
    short_banner = [
      "# ---------------------------------------------------------------------------",
      "# Shared pipeline",
      "#",
      "# Structural navigation",
      "#",
      "# Helpers below",
      "#",
      "# ---------------------------------------------------------------------------"
    ]

    long_banner =
      ["# ---------------------------------------------------------------------------"] ++
        List.duplicate("# architectural prose", 8) ++
        ["# ---------------------------------------------------------------------------"]

    assert violations_for_lines(short_banner, realization_path()) == []
    assert length(violations_for_lines(long_banner, realization_path())) == 1
  end

  test "a numbered walkthrough has no implicit exemption" do
    lines = [
      "# Phase 1",
      "#",
      "# 1. Resolve the binding.",
      "# 2. Normalize the path.",
      "# 3. Record the result.",
      "#",
      "# Phase 2",
      "# 1. Expand tagged tests."
    ]

    assert length(violations_for_lines(lines, realization_path())) == 1
  end

  test "a terminal reason-bearing marker exempts one realization block" do
    lines =
      List.duplicate("# implementation walkthrough", 7) ++
        ["# spec-lint:allow-long-comment=private helper data-shape walkthrough"]

    assert violations_for_lines(lines, realization_path()) == []
  end

  test "an empty or non-terminal marker grants no exemption" do
    empty_marker =
      List.duplicate("# implementation walkthrough", 7) ++
        ["# spec-lint:allow-long-comment="]

    non_terminal_marker =
      List.duplicate("# implementation walkthrough", 6) ++
        [
          "# spec-lint:allow-long-comment=private helper data-shape walkthrough",
          "# more prose"
        ]

    assert length(violations_for_lines(empty_marker, realization_path())) == 1
    assert length(violations_for_lines(non_terminal_marker, realization_path())) == 1
  end

  test "the marker is not honored outside the fixed realization corpus" do
    lines =
      List.duplicate("# implementation walkthrough", 7) ++
        ["# spec-lint:allow-long-comment=private helper data-shape walkthrough"]

    assert length(violations_for_lines(lines, "lib/specled_ex/other.ex")) == 1
  end

  defp corpus_files do
    @corpus_glob
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp violations_in_file(file) do
    file
    |> File.read!()
    |> String.split("\n", trim: false)
    |> violations_for_lines(file)
  end

  defp violations_for_lines(lines, file) do
    lines
    |> comment_blocks()
    |> Enum.reject(&compliant?(&1, file))
    |> Enum.map(fn block ->
      "#{file}:#{block.start_line}-#{block.end_line} " <>
        "(#{block_length(block.lines)} lines) has no terminal existing specled.decision.* pointer"
    end)
  end

  defp comment_blocks(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.chunk_by(fn {line, _line_number} -> comment_line?(line) end)
    |> Enum.flat_map(fn chunk ->
      case chunk do
        [{first_line, start_line} | _] ->
          if comment_line?(first_line) and
               block_length(Enum.map(chunk, &elem(&1, 0))) >= @minimum_block_lines do
            [{_last_line, end_line} | _] = Enum.reverse(chunk)

            [
              %{
                start_line: start_line,
                end_line: end_line,
                lines: Enum.map(chunk, &elem(&1, 0))
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp compliant?(block, file) do
    last_line = block.lines |> List.last() |> comment_text()

    adr_pointer?(last_line, adr_ids()) or
      (realization_file?(file) and allow_marker?(last_line))
  end

  defp comment_line?(line), do: Regex.match?(~r/^\s*#/, line)

  defp comment_text(line) do
    ~r/^\s*#\s?/
    |> Regex.replace(line, "")
    |> String.trim()
  end

  defp adr_pointer?(line, adr_ids) do
    case Regex.named_captures(@adr_pointer_pattern, line) do
      %{"id" => id} -> MapSet.member?(adr_ids, id)
      nil -> false
    end
  end

  defp allow_marker?(line), do: Regex.match?(@allow_marker_pattern, line)

  defp block_length(lines) do
    Enum.count(lines, fn line ->
      line
      |> comment_text()
      |> then(&(not Regex.match?(@separator_pattern, &1)))
    end)
  end

  defp adr_ids do
    ".spec/decisions/*.md"
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> Path.rootname()))
    |> MapSet.new()
  end

  defp realization_file?(file), do: Regex.match?(@corpus_path_pattern, file)
  defp realization_path, do: "lib/specled_ex/realization/example.ex"
end
