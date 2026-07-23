defmodule SpecLedEx.FindingMessageTest do
  use ExUnit.Case, async: true

  alias SpecLedEx.FindingMessage

  describe "finalize/2" do
    test "produces the canonical prose + fenced fix: block shape" do
      assert FindingMessage.finalize("ADR widened.", "fix: revert.") ==
               "ADR widened.\n\n```\nfix: revert.\n```"
    end

    test "trims trailing whitespace on the body only, no trailing newline" do
      assert FindingMessage.finalize(
               "Line one.  \nLine two trailing spaces   ",
               "fix: do the thing."
             ) ==
               "Line one.  \nLine two trailing spaces\n\n```\nfix: do the thing.\n```"
    end

    test "output round-trips through the review/html fix-block parser" do
      # finalize/2's output must match the fix-block shape that the real parser,
      # SpecLedEx.Review.Html.split_fix_block/1 (a private defp), expects. This
      # asserts finalize's output against a snapshot of that regex — it does NOT
      # pin the two modules in lockstep (editing the real regex would not fail
      # here). The real parser path is covered end-to-end in review/html_test.exs.
      message =
        FindingMessage.finalize("Some prose here.", "fix: apply the sanctioned resolution.")

      assert Regex.run(~r/^(.*?)\n*```\n(fix:[^\n]*(?:\n[^\n]*)*)\n```\s*$/s, message) ==
               [message, "Some prose here.", "fix: apply the sanctioned resolution."]
    end
  end
end
