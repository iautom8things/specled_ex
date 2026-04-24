defmodule SpecLedEx.TaggedTestsTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.tagged_tests.build_command",
               "specled.tagged_tests.build_command_combines_backed_ids",
               "specled.tagged_tests.build_command_drops_unbacked_ids",
               "specled.tagged_tests.build_command_includes_integration_flag",
               "specled.tagged_tests.build_command_no_tests_when_all_unbacked",
               "specled.tagged_tests.collect_entries"
             ]

  alias SpecLedEx.TaggedTests

  describe "collect_entries/1" do
    @tag spec: "specled.tagged_tests.collect_entries"
    test "gathers executable tagged_tests verifications and skips non-executable ones" do
      subjects = [
        subject_with(
          "subject.one",
          ".spec/specs/one.spec.md",
          [
            %{"kind" => "tagged_tests", "covers" => ["a.one", "a.two"], "execute" => true},
            %{"kind" => "tagged_tests", "covers" => ["a.three"]}
          ]
        ),
        subject_with(
          "subject.two",
          ".spec/specs/two.spec.md",
          [
            %{"kind" => "command", "target" => "mix test", "covers" => ["b.one"], "execute" => true},
            %{"kind" => "tagged_tests", "covers" => ["b.two"], "execute" => true}
          ]
        )
      ]

      entries = TaggedTests.collect_entries(subjects)

      assert length(entries) == 2
      assert Enum.any?(entries, &(&1.key == {"subject.one", ".spec/specs/one.spec.md", 0}))
      assert Enum.any?(entries, &(&1.key == {"subject.two", ".spec/specs/two.spec.md", 1}))

      covers_union = entries |> Enum.flat_map(& &1.covers) |> Enum.sort()
      assert covers_union == ["a.one", "a.two", "b.two"]
    end

    @tag spec: "specled.tagged_tests.collect_entries"
    test "returns an empty list when no tagged_tests verifications are present" do
      subjects = [
        subject_with("s.only_command", ".spec/specs/only_command.spec.md", [
          %{"kind" => "command", "target" => "mix test", "covers" => ["x"], "execute" => true}
        ])
      ]

      assert TaggedTests.collect_entries(subjects) == []
    end
  end

  describe "build_command/2" do
    @tag spec: "specled.tagged_tests.build_command"
    test "combines all covered ids into a single mix test invocation" do
      tag_map = %{
        "a.one" => [%{file: "test/a_test.exs", line: 3, test_name: "t1"}],
        "a.two" => [%{file: "test/a_test.exs", line: 9, test_name: "t2"}],
        "b.one" => [%{file: "test/b_test.exs", line: 4, test_name: "b1"}]
      }

      assert {:ok, command} = TaggedTests.build_command(["a.one", "a.two", "b.one"], tag_map)

      assert command =~ "mix test"
      assert command =~ "--only spec:a.one"
      assert command =~ "--only spec:a.two"
      assert command =~ "--only spec:b.one"
      assert command =~ "test/a_test.exs"
      assert command =~ "test/b_test.exs"

      assert length(String.split(command, "test/a_test.exs")) == 2
    end

    @tag spec: "specled.tagged_tests.build_command"
    test "drops cover ids that have no tag entry but keeps the others" do
      tag_map = %{"a.one" => [%{file: "test/a_test.exs", line: 3, test_name: "t1"}]}

      assert {:ok, command} = TaggedTests.build_command(["a.one", "missing.id"], tag_map)

      assert command =~ "--only spec:a.one"
      refute command =~ "missing.id"
    end

    @tag spec: "specled.tagged_tests.build_command"
    test "returns :no_tests when none of the cover ids have tag entries" do
      assert TaggedTests.build_command(["missing"], %{}) == :no_tests
    end

    @tag spec: "specled.tagged_tests.build_command"
    test "accepts string-keyed tag entries (as serialized from state.json)" do
      tag_map = %{"a.one" => [%{"file" => "test/a_test.exs"}]}

      assert {:ok, command} = TaggedTests.build_command(["a.one"], tag_map)
      assert command =~ "test/a_test.exs"
    end

    @tag spec: "specled.tagged_tests.build_command_includes_integration_flag"
    test "appends --include integration after the --only flags and before the files" do
      tag_map = %{
        "a.one" => [%{file: "test/a_test.exs", line: 3, test_name: "t1"}],
        "b.one" => [%{file: "test/b_test.exs", line: 5, test_name: "t2"}]
      }

      assert {:ok, command} = TaggedTests.build_command(["a.one", "b.one"], tag_map)

      assert command =~ "--include integration"

      include_idx = index_of(command, "--include integration")
      only_idx = index_of(command, "--only spec:")
      file_idx = index_of(command, "test/a_test.exs")

      assert only_idx < include_idx
      assert include_idx < file_idx
    end
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp subject_with(id, file, verifications) do
    %{
      "file" => file,
      "meta" => %{"id" => id, "kind" => "module", "status" => "active"},
      "verification" => verifications
    }
  end
end
