defmodule SpecLedEx.JsonTest do
  use SpecLedEx.Case

  alias SpecLedEx.Json

  test "read returns an empty map for missing and invalid files", %{root: root} do
    missing = Path.join(root, "missing.json")
    invalid = Path.join(root, "invalid.json")

    File.write!(invalid, "{not json}")

    assert Json.read(missing) == %{}
    assert Json.read(invalid) == %{}
  end

  test "write! creates parent directories and persists json data", %{root: root} do
    path = Path.join(root, "nested/state.json")

    assert Json.write!(path, %{"value" => 1}) == :written

    assert File.exists?(path)
    assert Json.read(path) == %{"value" => 1}
  end

  test "write! canonicalizes key order and skips unchanged writes", %{root: root} do
    path = Path.join(root, "nested/canonical.json")

    assert Json.write!(path, %{"b" => 1, "a" => %{"d" => 4, "c" => 3}}) == :written
    first = File.read!(path)

    assert first =~ ~s("a": {\n    "c": 3,\n    "d": 4\n  },\n  "b": 1)

    assert Json.write!(path, %{"a" => %{"c" => 3, "d" => 4}, "b" => 1}) == :unchanged
    assert File.read!(path) == first
  end
end
