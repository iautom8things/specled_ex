defmodule SpecLedEx.TagScannerTest do
  use SpecLedEx.Case

  alias SpecLedEx.TagScanner

  # AST pinning tests — these document the exact quoted shape the scanner
  # pattern-matches against. If Elixir changes how @tag/@moduletag attribute
  # assignments parse, these tests will fail and the scanner patterns must be
  # updated in lockstep.
  describe "AST pinning (Elixir ~> 1.18)" do
    test "@tag spec: <string> is @-attribute → tag/1 → keyword → spec/binary" do
      {:ok, ast} = Code.string_to_quoted(~S|@tag spec: "auth.login"|)

      assert {:@, _, [{:tag, _, [[{:spec, "auth.login"}]]}]} = ast
    end

    test "@tag [spec: <string>, timeout: int] is @-attribute → tag/1 → keyword list" do
      {:ok, ast} = Code.string_to_quoted(~S|@tag [spec: "auth.logout", timeout: 5_000]|)

      assert {:@, _, [{:tag, _, [[{:spec, "auth.logout"}, {:timeout, 5_000}]]}]} = ast
    end

    test "@tag spec: [<str>, <str>] carries list as value" do
      {:ok, ast} = Code.string_to_quoted(~S|@tag spec: ["a.one", "a.two"]|)

      assert {:@, _, [{:tag, _, [[{:spec, ["a.one", "a.two"]}]]}]} = ast
    end

    test "@moduletag spec: <string> uses moduletag/1" do
      {:ok, ast} = Code.string_to_quoted(~S|@moduletag spec: "domain.root"|)

      assert {:@, _, [{:moduletag, _, [[{:spec, "domain.root"}]]}]} = ast
    end

    test "@tag :slow carries an atom arg, no keyword" do
      {:ok, ast} = Code.string_to_quoted("@tag :slow")

      assert {:@, _, [{:tag, _, [:slow]}]} = ast
    end

    test "@tag spec: @attr carries a nested @-attribute ast as value" do
      {:ok, ast} = Code.string_to_quoted("@tag spec: @module_attr")

      assert {:@, _, [{:tag, _, [[{:spec, inner_ast}]]}]} = ast
      assert match?({:@, _, [{:module_attr, _, _}]}, inner_ast)
    end
  end

  describe "scan_file/1 — literal string form" do
    @tag spec: "specled.tag_scanning.supported_forms"
    test "extracts a single @tag spec: id", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @tag spec: "auth.login"
          test "logs in" do
            assert true
          end
        end
        """)

      assert {:ok, tags} = TagScanner.scan_file(path)
      assert [%{id: "auth.login", test_name: "logs in"}] = tags
    end
  end

  describe "scan_file/1 — keyword list form" do
    @tag spec: "specled.tag_scanning.supported_forms"
    test "extracts spec from a keyword list, ignoring other keys", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @tag [spec: "auth.logout", timeout: 5_000]
          test "logs out" do
            assert true
          end
        end
        """)

      assert {:ok, [%{id: "auth.logout", test_name: "logs out"}]} = TagScanner.scan_file(path)
    end
  end

  describe "scan_file/1 — list of ids form" do
    @tag spec: "specled.tag_scanning.supported_forms"
    test "extracts all ids from a list literal", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @tag spec: ["a.one", "a.two"]
          test "multi" do
            assert true
          end
        end
        """)

      assert {:ok, tags} = TagScanner.scan_file(path)
      ids = tags |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a.one", "a.two"]
      assert Enum.all?(tags, &(&1.test_name == "multi"))
    end
  end

  describe "scan_file/1 — @moduletag" do
    @tag spec: "specled.tag_scanning.moduletag_applies_to_all_tests"
    test "attaches to every test in the module", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @moduletag spec: "domain.root"

          test "first" do
            assert true
          end

          test "second" do
            assert true
          end
        end
        """)

      assert {:ok, tags} = TagScanner.scan_file(path)
      names = tags |> Enum.map(& &1.test_name) |> Enum.sort()
      assert names == ["first", "second"]
      assert Enum.all?(tags, &(&1.id == "domain.root"))
    end
  end

  describe "scan_file/1 — dynamic values" do
    @tag spec: "specled.tag_scanning.dynamic_values_reported"
    test "detects non-literal values and reports them separately", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @module_attr "some-id"

          @tag spec: @module_attr
          test "dynamic" do
            assert true
          end
        end
        """)

      assert {:ok, tags, dynamic} = TagScanner.scan_file(path, include_dynamic: true)
      assert tags == []
      assert [%{file: ^path, line: line, test_name: "dynamic"}] = dynamic
      assert is_integer(line)
    end
  end

  describe "scan_file/1 — non-spec tags" do
    @tag spec: "specled.tag_scanning.ignored_non_spec_tags"
    test "ignores @tag annotations without a spec key", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @tag :slow
          test "slow" do
            assert true
          end
        end
        """)

      assert {:ok, []} = TagScanner.scan_file(path)
    end
  end

  describe "scan_file/1 — deduplication" do
    @tag spec: "specled.tag_scanning.deduplicated_matches"
    test "collapses identical file/line/test entries for the same id", %{root: root} do
      path =
        write_test_file(root, "test/example_test.exs", """
        defmodule ExampleTest do
          use ExUnit.Case

          @tag spec: "a.one"
          @tag spec: "a.one"
          test "duplicate" do
            assert true
          end
        end
        """)

      assert {:ok, tags} = TagScanner.scan_file(path)
      assert length(Enum.filter(tags, &(&1.id == "a.one"))) == 1
    end
  end

  describe "scan/2 aggregation" do
    @tag spec: "specled.tag_scanning.scan_aggregates_results"
    test "aggregates tags across files and records parse errors", %{root: root} do
      write_test_file(root, "test/ok_test.exs", """
      defmodule OkTest do
        use ExUnit.Case

        @tag spec: "ok.one"
        test "works" do
          assert true
        end
      end
      """)

      broken_path = write_test_file(root, "test/broken_test.exs", "defmodule do do\n")

      assert {:ok, tag_map, parse_errors, dynamic} =
               TagScanner.scan([Path.join(root, "test")])

      assert Map.has_key?(tag_map, "ok.one")
      assert [%{id: "ok.one", test_name: "works"}] = tag_map["ok.one"]
      assert [%{file: ^broken_path, reason: _}] = parse_errors
      assert dynamic == []
    end

    @tag spec: "specled.tag_scanning.parse_errors_surfaced"
    test "collects parse errors without silently skipping other files", %{root: root} do
      write_test_file(root, "test/good_test.exs", """
      defmodule GoodTest do
        use ExUnit.Case

        @tag spec: "good.one"
        test "good" do
          assert true
        end
      end
      """)

      write_test_file(root, "test/broken_test.exs", "defmodule do do\n")

      assert {:ok, tag_map, parse_errors, _dynamic} =
               TagScanner.scan([Path.join(root, "test")])

      assert Map.has_key?(tag_map, "good.one")
      assert length(parse_errors) == 1
    end

    @tag spec: "specled.tag_scanning.dynamic_values_reported"
    test "surfaces dynamic entries aggregated across files", %{root: root} do
      write_test_file(root, "test/dynamic_test.exs", """
      defmodule DynamicTest do
        use ExUnit.Case

        @module_attr "some-id"

        @tag spec: @module_attr
        test "dynamic" do
          assert true
        end
      end
      """)

      assert {:ok, _tag_map, _parse_errors, dynamic} =
               TagScanner.scan([Path.join(root, "test")])

      assert [%{test_name: "dynamic"}] = dynamic
    end
  end

  defp write_test_file(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end
end
