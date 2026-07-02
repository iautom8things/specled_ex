defmodule SpecLedEx.TaggedTestsTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.tagged_tests.build_command",
               "specled.tagged_tests.build_command_appends_formatters",
               "specled.tagged_tests.build_command_combines_backed_ids",
               "specled.tagged_tests.build_command_drops_unbacked_ids",
               "specled.tagged_tests.build_command_file_selectors_for_list_tags",
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
            %{
              "kind" => "command",
              "target" => "mix test",
              "covers" => ["b.one"],
              "execute" => true
            },
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
    test "combines all covered ids into a single mix test invocation using test files" do
      tag_map = %{
        "a.one" => [%{file: "test/a_test.exs", line: 3, test_line: 4, test_name: "t1"}],
        "a.two" => [%{file: "test/a_test.exs", line: 9, test_line: 10, test_name: "t2"}],
        "b.one" => [%{file: "test/b_test.exs", line: 4, test_line: 5, test_name: "b1"}]
      }

      assert {:ok, command} = TaggedTests.build_command(["a.one", "a.two", "b.one"], tag_map)

      assert command =~ "mix test"
      refute command =~ "--only spec:"
      assert command =~ "test/a_test.exs"
      assert command =~ "test/b_test.exs"

      assert length(String.split(command, "test/a_test.exs")) == 2
    end

    @tag spec: "specled.tagged_tests.build_command"
    test "drops cover ids that have no tag entry but keeps the others" do
      tag_map = %{"a.one" => [%{file: "test/a_test.exs", line: 3, test_line: 4, test_name: "t1"}]}

      assert {:ok, command} = TaggedTests.build_command(["a.one", "missing.id"], tag_map)

      assert command =~ "test/a_test.exs"
      refute command =~ "missing.id"
    end

    @tag spec: "specled.tagged_tests.build_command"
    test "returns :no_tests when none of the cover ids have tag entries" do
      assert TaggedTests.build_command(["missing"], %{}) == :no_tests
    end

    @tag spec: "specled.tagged_tests.build_command"
    test "accepts string-keyed tag entries (as serialized from state.json)" do
      tag_map = %{"a.one" => [%{"file" => "test/a_test.exs", "test_line" => 4}]}

      assert {:ok, command} = TaggedTests.build_command(["a.one"], tag_map)
      assert command =~ "test/a_test.exs"
    end

    @tag spec: "specled.tagged_tests.build_command_includes_integration_flag"
    test "appends --include integration before the test files" do
      tag_map = %{
        "a.one" => [%{file: "test/a_test.exs", line: 3, test_line: 4, test_name: "t1"}],
        "b.one" => [%{file: "test/b_test.exs", line: 5, test_line: 6, test_name: "t2"}]
      }

      assert {:ok, command} = TaggedTests.build_command(["a.one", "b.one"], tag_map)

      assert command =~ "--include integration"

      include_idx = index_of(command, "--include integration")
      base_idx = index_of(command, "mix test")
      file_idx = index_of(command, "test/a_test.exs")

      assert base_idx < include_idx
      assert include_idx < file_idx
    end

    @tag spec: "specled.tagged_tests.build_command_appends_formatters"
    test "appends the streaming formatter flags after --include integration, before files" do
      tag_map = %{
        "a.one" => [%{file: "test/a_test.exs", line: 3, test_line: 4, test_name: "t1"}]
      }

      assert {:ok, command} = TaggedTests.build_command(["a.one"], tag_map)

      assert command =~ "--formatter SpecLedEx.TaggedTests.Formatter"
      assert command =~ "--formatter ExUnit.CLIFormatter"

      include_idx = index_of(command, "--include integration")
      formatter_idx = index_of(command, "--formatter SpecLedEx.TaggedTests.Formatter")
      cli_idx = index_of(command, "--formatter ExUnit.CLIFormatter")
      file_idx = index_of(command, "test/a_test.exs")

      assert include_idx < formatter_idx
      assert formatter_idx < cli_idx
      assert cli_idx < file_idx
    end

    @tag spec: "specled.tagged_tests.build_command_file_selectors_for_list_tags"
    test "uses test files so list-valued spec tags execute under mix test", %{root: root} do
      path =
        write_test_file(root, "test/list_filter_test.exs", """
        defmodule ListFilterTest do
          use ExUnit.Case

          @tag spec: ["a.one", "a.two"]
          test "list tagged" do
            assert true
          end

          @tag spec: "a.one"
          test "scalar tagged" do
            assert true
          end
        end
        """)

      assert {:ok, tags} = SpecLedEx.TagScanner.scan_file(path)
      tag_map = Enum.group_by(tags, & &1.id)

      assert {:ok, command} = TaggedTests.build_command(["a.two"], tag_map)

      refute command =~ "--only spec:a.two"
      assert command =~ path

      assert {_output, 0} =
               System.cmd("sh", ["-c", command], cd: File.cwd!(), stderr_to_stdout: true)
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

  defp write_test_file(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end
end
