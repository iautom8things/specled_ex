defmodule SpecLedExTest do
  use ExUnit.Case
  @moduletag spec: ["specled.index.canonical_state_output", "specled.index.json_resilience", "specled.index.subject_and_decision_index", "specled.package.declarative_governance", "specled.package.index_and_state"]

  test "build_index returns an index map" do
    root =
      System.tmp_dir!()
      |> Path.join("specled_ex_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(Path.join(root, ".spec/specs"))

    File.write!(
      Path.join(root, ".spec/specs/example.spec.md"),
      """
      # Example

      ```spec-meta
      {"id":"example.subject","kind":"module","status":"active"}
      ```

      ```spec-requirements
      [{"id":"example.requirement","statement":"Example statement"}]
      ```
      """
    )

    index = SpecLedEx.build_index(root)
    assert is_map(index)
    assert Map.has_key?(index, "subjects")
    assert index["summary"]["subjects"] == 1
  end

  describe "normalize_for_state/1 round-trip" do
    # The T1 merge gate: in-memory normalization must match the on-disk JSON
    # that write_state writes when no verification report is supplied. This
    # is what lets AppendOnly consume either form interchangeably.

    test "round-trips over an empty corpus" do
      root = make_tmp_root()
      File.mkdir_p!(Path.join(root, ".spec/specs"))
      File.mkdir_p!(Path.join(root, ".spec/decisions"))

      index = SpecLedEx.build_index(root)
      assert_round_trips(index, root)
    end

    test "round-trips over a subject + requirement + scenario + verification" do
      root = make_tmp_root()
      File.mkdir_p!(Path.join(root, ".spec/specs"))

      File.write!(
        Path.join(root, ".spec/specs/example.spec.md"),
        """
        # Example

        ```spec-meta
        {"id":"example.subject","kind":"module","status":"active"}
        ```

        ```spec-requirements
        [{"id":"example.requirement","statement":"Example statement","priority":"must"}]
        ```

        ```spec-scenarios
        [{"id":"example.scenario.one","covers":["example.requirement"]}]
        ```

        ```spec-verification
        [{"kind":"source_file","target":"lib/example.ex","execute":false,"covers":["example.requirement"]}]
        ```
        """
      )

      index = SpecLedEx.build_index(root)
      assert_round_trips(index, root)
    end

    test "round-trips over a corpus carrying structured ADR fields" do
      root = make_tmp_root()
      File.mkdir_p!(Path.join(root, ".spec/specs"))
      File.mkdir_p!(Path.join(root, ".spec/decisions"))

      File.write!(
        Path.join(root, ".spec/specs/example.spec.md"),
        """
        # Example

        ```spec-meta
        {"id":"example.subject","kind":"module","status":"active"}
        ```

        ```spec-requirements
        [{"id":"example.requirement","statement":"The system MUST foo.","priority":"must"}]
        ```
        """
      )

      File.write!(
        Path.join(root, ".spec/decisions/example.decision.one.md"),
        """
        ---
        id: example.decision.one
        status: accepted
        date: 2026-04-23
        affects:
          - example.subject
        change_type: clarifies
        ---

        # Example Decision

        ## Context

        Body.

        ## Decision

        Body.

        ## Consequences

        Body.
        """
      )

      index = SpecLedEx.build_index(root)
      assert_round_trips(index, root)

      # And make sure the structured ADR fields survive the round-trip.
      normalized = SpecLedEx.normalize_for_state(index)
      [decision | _] = normalized["decisions"]["items"]
      assert decision["id"] == "example.decision.one"
      assert decision["change_type"] == "clarifies"
    end

    defp make_tmp_root do
      path =
        System.tmp_dir!()
        |> Path.join("specled_ex_normalize_#{System.unique_integer([:positive])}")

      File.rm_rf!(path)
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf(path) end)
      path
    end

    defp assert_round_trips(index, root) do
      output_path = Path.join(root, ".spec/state.json")
      File.rm(output_path)

      written_path = SpecLedEx.write_state(index, nil, root, ".spec/state.json")
      written = written_path |> File.read!() |> Jason.decode!()

      assert SpecLedEx.normalize_for_state(index) == written
    end
  end
end
