defmodule SpecLedEx.Realization.DriftTest do
  # covers: specled.use_tier.root_cause_dedupe
  # covers: specled.use_tier.hash_prefix_length
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

  describe "macro-provider root_cause dedupe (specled.use_tier.root_cause_dedupe)" do
    test "collapses N consumer drifts into one root_cause finding naming the provider" do
      provider_mod = SpecLedEx.MacroProviderFixture.A

      provider_delta = %{
        subject_id: "provider_subj",
        code: :branch_guard_realization_drift,
        tier: :use,
        provider: provider_mod,
        provider_mfa: {provider_mod, :__using__, 1},
        hash_prefix_before: "abc12345",
        hash_prefix_after: "def67890",
        consumers: [SpecLedEx.MacroFixture.C1, SpecLedEx.MacroFixture.C2, SpecLedEx.MacroFixture.C3]
      }

      consumer_deltas =
        for c <- ["consumer_c1_subj", "consumer_c2_subj", "consumer_c3_subj"] do
          %{subject_id: c, code: :branch_guard_realization_drift, tier: :expanded_behavior}
        end

      deltas = consumer_deltas ++ [provider_delta]

      pred = fn from, to ->
        # Each consumer subject depends on the provider subject.
        from in ["consumer_c1_subj", "consumer_c2_subj", "consumer_c3_subj"] and
          to == "provider_subj"
      end

      assert [result] = Drift.dedupe(deltas, pred)
      assert result.subject_id == "provider_subj"

      assert Enum.sort(result.root_cause_of) ==
               ["consumer_c1_subj", "consumer_c2_subj", "consumer_c3_subj"]

      assert %{
               provider: {SpecLedEx.MacroProviderFixture.A, :__using__, 1},
               tier: :use,
               hash_prefix_before: "abc12345",
               hash_prefix_after: "def67890",
               consumers_affected: 3,
               consumers: [
                 SpecLedEx.MacroFixture.C1,
                 SpecLedEx.MacroFixture.C2,
                 SpecLedEx.MacroFixture.C3
               ]
             } = result.root_cause
    end

    test "use-tier delta is always picked as root regardless of edge orientation" do
      # Even if pred says provider depends on consumer (inverted direction),
      # the use-tier delta still wins as root.
      provider_delta = %{
        subject_id: "P",
        code: :branch_guard_realization_drift,
        tier: :use,
        provider: SomeProvider,
        provider_mfa: {SomeProvider, :__using__, 1},
        hash_prefix_before: "11111111",
        hash_prefix_after: "22222222",
        consumers: [SomeConsumer]
      }

      consumer_delta = %{
        subject_id: "C",
        code: :branch_guard_realization_drift,
        tier: :expanded_behavior
      }

      pred = fn _from, _to -> true end

      assert [result] = Drift.dedupe([provider_delta, consumer_delta], pred)
      assert result.subject_id == "P"
      assert result.root_cause.tier == :use
      assert result.root_cause.consumers_affected == 1
    end

    test "8-character hex prefixes are preserved verbatim (specled.use_tier.hash_prefix_length)" do
      delta = %{
        subject_id: "P",
        code: :branch_guard_realization_drift,
        tier: :use,
        provider: SomeProvider,
        provider_mfa: {SomeProvider, :__using__, 1},
        hash_prefix_before: "deadbeef",
        hash_prefix_after: "cafef00d",
        consumers: [Cn1, Cn2]
      }

      assert [result] = Drift.dedupe([delta], fn _, _ -> false end)
      assert result.root_cause.hash_prefix_before == "deadbeef"
      assert result.root_cause.hash_prefix_after == "cafef00d"
      assert String.length(result.root_cause.hash_prefix_before) == 8
      assert String.length(result.root_cause.hash_prefix_after) == 8
    end

    test "non-use-tier deltas do not get a root_cause map injected" do
      delta = %{
        subject_id: "S",
        code: :branch_guard_realization_drift,
        tier: :expanded_behavior
      }

      assert [result] = Drift.dedupe([delta], fn _, _ -> false end)
      refute Map.has_key?(result, :root_cause)
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
