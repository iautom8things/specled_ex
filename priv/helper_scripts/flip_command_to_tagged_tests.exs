#!/usr/bin/env elixir
# Rewrites every `kind: command` verification entry whose target starts with
# `mix test ...` to a `kind: tagged_tests` entry (no target, same covers,
# same execute flag). Non-`mix test` command entries (e.g. `mix spec.index`)
# are left untouched.
#
# Usage (from repo root):
#     elixir priv/helper_scripts/flip_command_to_tagged_tests.exs

defmodule FlipCommandToTaggedTests do
  @spec_glob ".spec/specs/*.spec.md"

  def run do
    @spec_glob
    |> Path.wildcard()
    |> Enum.each(&process_file/1)
  end

  defp process_file(path) do
    original = File.read!(path)

    new =
      Regex.replace(
        ~r/```yaml spec-verification\n(.*?)\n```/s,
        original,
        fn full, inner ->
          rewritten = rewrite_block(inner)
          "```yaml spec-verification\n" <> rewritten <> "\n```"
        end
      )

    if new != original do
      File.write!(path, new)
      IO.puts("updated #{path}")
    end
  end

  defp rewrite_block(block) do
    # Split the block on entry boundaries ("\n- kind:" at column 0).
    # Keep the leading context (whitespace before the first entry) intact.
    parts = Regex.split(~r/\n(?=-\s+kind:)/, block)

    parts
    |> Enum.map(&rewrite_entry/1)
    |> Enum.join("\n")
  end

  defp rewrite_entry(entry) do
    cond do
      not (entry =~ ~r/^-\s+kind:\s*command/m) ->
        entry

      true ->
        target_line = Regex.run(~r/^(\s*)target:\s*(.+?)\s*$/m, entry)

        case target_line do
          [_, _indent, target] ->
            target = String.trim(target)

            if String.starts_with?(target, "mix test") do
              entry
              # 1. Replace `kind: command` with `kind: tagged_tests`.
              |> String.replace(~r/^(\s*-\s+)kind:\s*command\s*$/m, "\\1kind: tagged_tests")
              # 2. Drop the `target: mix test ...` line entirely (including its
              #    trailing newline if any).
              |> String.replace(~r/\n\s*target:\s*mix test[^\n]*/m, "")
            else
              entry
            end

          _ ->
            entry
        end
    end
  end
end

FlipCommandToTaggedTests.run()
