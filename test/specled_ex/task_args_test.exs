defmodule SpecLedEx.TaskArgsTest do
  use ExUnit.Case, async: true

  alias SpecLedEx.TaskArgs

  test "validate returns one error message without raising" do
    assert {:error, "Invalid arguments for spec.check: --unknown, \"extra\""} =
             TaskArgs.validate("spec.check", ["extra"], [{"--unknown", nil}])
  end

  test "validate! keeps the raising API for existing callers" do
    assert_raise Mix.Error, "Invalid arguments for spec.sync: --unknown", fn ->
      TaskArgs.validate!("spec.sync", [], [{"--unknown", nil}])
    end
  end
end
