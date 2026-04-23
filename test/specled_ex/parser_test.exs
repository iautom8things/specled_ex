defmodule SpecLedEx.ParserTest do
  use SpecLedEx.Case

  alias SpecLedEx.Parser
  alias SpecLedEx.Schema.{Exception, Meta, Requirement, Scenario, Verification}

  test "parse_file extracts all supported blocks and title", %{root: root} do
    path =
      write_spec(
        root,
        "example",
        """
        # Example Subject

        ```spec-meta
        id: example.subject
        kind: module
        status: active
        summary: Example summary
        ```

        ```spec-requirements
        - id: example.requirement
          statement: Example statement
        ```

        ```spec-scenarios
        - id: example.scenario
          covers:
            - example.requirement
          given:
            - a precondition
          when:
            - an action occurs
          then:
            - the outcome is observed
        ```

        ```spec-verification
        - kind: source_file
          target: lib/example.ex
          covers:
            - example.requirement
        ```

        ```spec-exceptions
        - id: example.exception
          covers:
            - example.requirement
          reason: accepted gap
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert spec["file"] == ".spec/specs/example.spec.md"
    assert spec["title"] == "Example Subject"
    assert %Meta{summary: "Example summary"} = spec["meta"]
    assert [%Requirement{id: "example.requirement"}] = spec["requirements"]
    assert [%Scenario{id: "example.scenario"}] = spec["scenarios"]
    assert [%Verification{kind: "source_file", target: "lib/example.ex"}] = spec["verification"]
    assert [%Exception{id: "example.exception", reason: "accepted gap"}] = spec["exceptions"]
    assert spec["parse_errors"] == []
  end

  test "parse_file returns nil title when no h1 is present", %{root: root} do
    path =
      write_spec(
        root,
        "untitled",
        """
        Paragraph only.

        ```spec-meta
        id: untitled.subject
        kind: module
        status: active
        ```
        """
      )

    assert Parser.parse_file(path, root)["title"] == nil
  end

  test "parse_file records decode and shape errors without crashing", %{root: root} do
    path =
      write_spec(
        root,
        "invalid",
        """
        # Invalid

        ```spec-meta
        id: [
        ```

        ```spec-requirements
        id: wrong-shape
        statement: still wrong
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert Enum.any?(spec["parse_errors"], &String.contains?(&1, "spec-meta decode failed"))
    assert "spec-requirements must decode to a list" in spec["parse_errors"]
  end

  test "parse_file rejects duplicate spec-meta blocks even when the first one is malformed", %{
    root: root
  } do
    path =
      write_spec(
        root,
        "duplicate_meta",
        """
        # Duplicate Meta

        ```spec-meta
        id: [
        ```

        ```spec-meta
        id: duplicate.subject
        kind: module
        status: active
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert Enum.any?(spec["parse_errors"], &String.contains?(&1, "spec-meta decode failed"))
    assert "spec-meta may only appear once per file" in spec["parse_errors"]
    assert spec["meta"] == nil
  end

  test "parse_file rejects duplicate empty list-backed blocks", %{root: root} do
    path =
      write_spec(
        root,
        "duplicate_requirements",
        """
        # Duplicate Requirements

        ```spec-meta
        id: duplicate.requirements
        kind: module
        status: active
        ```

        ```spec-requirements
        []
        ```

        ```spec-requirements
        []
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert "spec-requirements may only appear once per file" in spec["parse_errors"]
  end

  test "parse_file accepts realized_by on spec-meta and spec-requirements", %{root: root} do
    path =
      write_spec(
        root,
        "bindings",
        """
        # Bindings

        ```spec-meta
        id: bindings.subject
        kind: module
        status: active
        realized_by:
          api_boundary:
            - "MyMod.a/1"
          implementation:
            - "MyMod.a/1"
        ```

        ```spec-requirements
        - id: bindings.override
          statement: An override
          priority: must
          realized_by:
            api_boundary:
              - "MyMod.c/3"
        - id: bindings.plain
          statement: No override
          priority: must
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert spec["parse_errors"] == []
    assert %Meta{realized_by: %{"api_boundary" => ["MyMod.a/1"]}} = spec["meta"]

    [%Requirement{id: "bindings.override", realized_by: override} | _] = spec["requirements"]
    assert override == %{"api_boundary" => ["MyMod.c/3"]}

    plain =
      Enum.find(spec["requirements"], fn req ->
        match?(%Requirement{id: "bindings.plain"}, req)
      end)

    assert plain.realized_by == nil
  end

  test "parse_file rejects unknown realized_by tiers with an error naming the tier",
       %{root: root} do
    path =
      write_spec(
        root,
        "bad_binding",
        """
        # Bad Binding

        ```spec-meta
        id: bad_binding.subject
        kind: module
        status: active
        realized_by:
          shenanigans:
            - "Foo"
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert Enum.any?(spec["parse_errors"], fn err ->
             String.contains?(err, "shenanigans") and
               String.contains?(err, ".spec/specs/bad_binding.spec.md")
           end),
           "expected parse error naming 'shenanigans' and the subject file, got: " <>
             inspect(spec["parse_errors"])
  end

  describe "info-string tokens" do
    test "language-first fences (```yaml spec-meta) parse like bare tags", %{root: root} do
      path =
        write_spec(
          root,
          "lang_first",
          """
          # Language First

          ```yaml spec-meta
          id: lang_first.subject
          kind: module
          status: active
          ```

          ```yaml spec-requirements
          - id: lang_first.requirement
            statement: Example statement
          ```
          """
        )

      spec = Parser.parse_file(path, root)

      assert spec["parse_errors"] == []
      assert %Meta{id: "lang_first.subject"} = spec["meta"]
      assert [%Requirement{id: "lang_first.requirement"}] = spec["requirements"]
    end

    test "tag-first fences with trailing language token (```spec-meta yaml) still parse",
         %{root: root} do
      path =
        write_spec(
          root,
          "tag_first",
          """
          # Tag First

          ```spec-meta yaml
          id: tag_first.subject
          kind: module
          status: active
          ```
          """
        )

      spec = Parser.parse_file(path, root)

      assert spec["parse_errors"] == []
      assert %Meta{id: "tag_first.subject"} = spec["meta"]
    end

    test "non-spec fenced blocks are ignored", %{root: root} do
      path =
        write_spec(
          root,
          "mixed_fences",
          """
          # Mixed Fences

          ```elixir
          defmodule Sample do
          end
          ```

          ```yaml spec-meta
          id: mixed.subject
          kind: module
          status: active
          ```

          ```bash
          mix spec.check
          ```
          """
        )

      spec = Parser.parse_file(path, root)

      assert spec["parse_errors"] == []
      assert %Meta{id: "mixed.subject"} = spec["meta"]
    end

    test "duplicate detection treats tagged and bare fences as the same block kind",
         %{root: root} do
      path =
        write_spec(
          root,
          "mixed_duplicates",
          """
          # Mixed Duplicates

          ```yaml spec-meta
          id: mixed_duplicates.subject
          kind: module
          status: active
          ```

          ```spec-meta
          id: mixed_duplicates.other
          kind: module
          status: active
          ```
          """
        )

      spec = Parser.parse_file(path, root)

      assert "spec-meta may only appear once per file" in spec["parse_errors"]
    end
  end

  test "parse_file preserves malformed list items for later reporting", %{root: root} do
    path =
      write_spec(
        root,
        "malformed_items",
        """
        # Malformed Items

        ```spec-meta
        id: malformed.items
        kind: module
        status: active
        ```

        ```spec-requirements
        - just-a-string
        ```
        """
      )

    spec = Parser.parse_file(path, root)

    assert spec["requirements"] == ["just-a-string"]

    assert Enum.any?(
             spec["parse_errors"],
             &String.contains?(&1, "spec-requirements[0] validation failed")
           )
  end
end
