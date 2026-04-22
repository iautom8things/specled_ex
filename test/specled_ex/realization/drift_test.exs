defmodule SpecLedEx.Realization.DriftTest do
  use ExUnit.Case, async: true

  alias SpecLedEx.Realization.Drift

  describe "dedupe/2" do
    test "returns the single delta unchanged when there is no dependency" do
      deltas = [%{subject_id: "a", kind: :drift}]

      assert [%{subject_id: "a", root_cause_of: []}] =
               Drift.dedupe(deltas, fn _, _ -> false end)
    end

    test "collapses a linear DAG to the provider" do
      # a depends on b; b depends on c → provider is c
      deltas = [
        %{subject_id: "a"},
        %{subject_id: "b"},
        %{subject_id: "c"}
      ]

      pred = fn
        "a", "b" -> true
        "b", "c" -> true
        _, _ -> false
      end

      result = Drift.dedupe(deltas, pred)

      assert length(result) == 1
      [collapsed] = result
      assert collapsed.subject_id == "c"
      assert Enum.sort(collapsed.root_cause_of) == ["a", "b"]
    end

    test "independent subjects stay independent" do
      deltas = [%{subject_id: "a"}, %{subject_id: "b"}]

      result = Drift.dedupe(deltas, fn _, _ -> false end)

      ids = Enum.map(result, & &1.subject_id) |> Enum.sort()
      assert ids == ["a", "b"]
      Enum.each(result, fn d -> assert d.root_cause_of == [] end)
    end

    test "cyclic component picks lexicographically smallest id as root (tiebreak)" do
      deltas = [
        %{subject_id: "bbb.bar"},
        %{subject_id: "ccc.baz"},
        %{subject_id: "aaa.foo"}
      ]

      # All depend on each other (cycle): a→b, b→c, c→a
      pred = fn
        "aaa.foo", "bbb.bar" -> true
        "bbb.bar", "ccc.baz" -> true
        "ccc.baz", "aaa.foo" -> true
        _, _ -> false
      end

      [result] = Drift.dedupe(deltas, pred)

      assert result.subject_id == "aaa.foo"
      assert Enum.sort(result.root_cause_of) == ["bbb.bar", "ccc.baz"]
    end

    test "cyclic tiebreak is stable across invocations" do
      deltas = Enum.shuffle([%{subject_id: "aaa"}, %{subject_id: "bbb"}, %{subject_id: "ccc"}])

      pred = fn
        "aaa", "bbb" -> true
        "bbb", "ccc" -> true
        "ccc", "aaa" -> true
        _, _ -> false
      end

      first = Drift.dedupe(deltas, pred)
      second = Drift.dedupe(Enum.shuffle(deltas), pred)

      assert hd(first).subject_id == hd(second).subject_id
    end
  end

  describe "LOC cap + single-function API (hard contract from spec)" do
    test "Drift exports exactly one public function" do
      exports =
        Drift.__info__(:functions)
        |> Enum.reject(fn {name, _arity} ->
          name in [:__info__, :module_info]
        end)

      assert exports == [{:dedupe, 2}],
             "Drift must export exactly dedupe/2, got: #{inspect(exports)}"
    end

    test "Drift module source is ≤ 150 LOC (hard cap)" do
      source_path = Path.expand("../../../lib/specled_ex/realization/drift.ex", __DIR__)
      loc = source_path |> File.read!() |> String.split("\n") |> length()

      assert loc <= 150, "Drift.ex is #{loc} LOC; hard-capped at 150"
    end
  end
end
