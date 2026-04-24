#!/usr/bin/env elixir
# Adds a `@moduletag spec: [...]` line to every test module whose file is
# referenced by a `kind: command` mix-test verification in .spec/specs/*.spec.md.
#
# Usage (from repo root):
#     elixir priv/helper_scripts/tag_tests_from_specs.exs
#
# - Aggregates cover ids per test file across all spec files (union).
# - Merges with any existing `@moduletag spec: [...]` line present on the module.
# - Non-destructive: existing `@tag spec: "..."` annotations are left untouched.

defmodule TagTestsFromSpecs do
  @spec_glob ".spec/specs/*.spec.md"

  def run do
    files_to_covers = collect_files_to_covers()
    IO.puts("Aggregated #{map_size(files_to_covers)} test files with cover ids")

    Enum.each(files_to_covers, fn {file, covers} ->
      sorted = covers |> Enum.sort()
      apply_moduletag!(file, sorted)
      IO.puts("  tagged #{file} (#{length(sorted)} ids)")
    end)
  end

  defp collect_files_to_covers do
    @spec_glob
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn spec_path, acc ->
      File.read!(spec_path)
      |> verification_blocks()
      |> Enum.flat_map(&mix_test_entries/1)
      |> Enum.reduce(acc, fn {files, covers}, inner ->
        Enum.reduce(files, inner, fn file, m ->
          Map.update(m, file, MapSet.new(covers), &MapSet.union(&1, MapSet.new(covers)))
        end)
      end)
    end)
  end

  defp verification_blocks(content) do
    Regex.scan(~r/```yaml spec-verification\n(.*?)\n```/s, content, capture: :all_but_first)
    |> Enum.map(fn [inner] -> inner end)
  end

  defp mix_test_entries(block) do
    # Split at entries starting with "- kind:"
    entries = Regex.split(~r/\n(?=-\s+kind:)/, block)

    Enum.flat_map(entries, fn entry ->
      cond do
        not (entry =~ ~r/kind:\s*command/) ->
          []

        true ->
          case Regex.run(~r/^\s*target:\s*(.+?)\s*$/m, entry) do
            [_, target] ->
              target = String.trim(target)

              if String.starts_with?(target, "mix test") do
                covers =
                  Regex.scan(~r/^\s*-\s+([a-z][a-z0-9._]+)\s*$/m, entry, capture: :all_but_first)
                  |> Enum.map(fn [id] -> id end)

                tokens = String.split(target) |> Enum.drop(2)
                test_files = Enum.filter(tokens, &String.ends_with?(&1, ".exs"))

                [{test_files, covers}]
              else
                []
              end

            _ ->
              []
          end
      end
    end)
  end

  defp apply_moduletag!(file, covers) do
    src = File.read!(file)

    tag_line = build_tag_line(covers)

    new_src =
      case Regex.run(~r/^(\s*)@moduletag\s+spec:\s*\[(.*?)\]\s*$/ms, src, return: :index) do
        [{start, len}, {_indent_s, _indent_l}, {_ids_s, _ids_l}] ->
          # Replace the existing moduletag spec line with a merged union.
          existing_line = String.slice(src, start, len)

          existing_ids =
            Regex.scan(~r/"([a-z][a-z0-9._]+)"/, existing_line, capture: :all_but_first)
            |> Enum.map(fn [id] -> id end)

          merged = (existing_ids ++ covers) |> Enum.uniq() |> Enum.sort()
          replacement = build_tag_line_with_indent(merged, leading_ws(existing_line))
          String.slice(src, 0, start) <> replacement <> String.slice(src, start + len, String.length(src))

        nil ->
          insert_after_first_use(src, tag_line)
      end

    if new_src != src do
      File.write!(file, new_src)
    end
  end

  defp leading_ws(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, ws] -> ws
      _ -> "  "
    end
  end

  defp build_tag_line(covers) do
    build_tag_line_with_indent(covers, "  ")
  end

  defp build_tag_line_with_indent(covers, indent) do
    quoted = Enum.map(covers, &"\"#{&1}\"") |> Enum.join(", ")
    indent <> "@moduletag spec: [" <> quoted <> "]"
  end

  # Insert the @moduletag spec: line after the first `use ...` line inside the
  # first `defmodule ... do` block in the file. Fall back to inserting right
  # after the `defmodule ... do` line if no `use` is present.
  defp insert_after_first_use(src, tag_line) do
    lines = String.split(src, "\n", trim: false)

    {_, _, rev} =
      Enum.reduce(lines, {:scan, false, []}, fn line, {state, inserted?, acc} ->
        cond do
          inserted? ->
            {state, true, [line | acc]}

          state == :scan and line =~ ~r/^\s*defmodule\s+.+\sdo\s*$/ ->
            {:in_module_preamble, false, [line | acc]}

          state == :in_module_preamble and line =~ ~r/^\s*use\s+.+/ ->
            # Insert immediately after this use line.
            {:inserted, true, [tag_line, line | acc]}

          state == :in_module_preamble and line =~ ~r/^\s*(describe|test|setup|alias|import|require|@)/ ->
            # Reached code before `use`: insert the tag before this line.
            {:inserted, true, [line, tag_line | acc]}

          true ->
            {state, inserted?, [line | acc]}
        end
      end)

    Enum.reverse(rev) |> Enum.join("\n")
  end
end

TagTestsFromSpecs.run()
