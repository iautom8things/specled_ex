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
      # SpecLedEx.Review.HTML.split_fix_block/1 regex-parses the exact shape
      # finalize/2 emits; this pins the two in lockstep.
      message =
        FindingMessage.finalize("Some prose here.", "fix: apply the sanctioned resolution.")

      assert Regex.run(~r/^(.*?)\n*```\n(fix:[^\n]*(?:\n[^\n]*)*)\n```\s*$/s, message) ==
               [message, "Some prose here.", "fix: apply the sanctioned resolution."]
    end
  end
end
