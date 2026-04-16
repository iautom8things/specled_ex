defmodule SpecLedEx.IndexStateTagTest do
  use SpecLedEx.Case

  alias SpecLedEx.Index

  @tag spec: "specled.index.tag_data_conditional"
  test "populates test_tags keys when enabled via config", %{root: root} do
    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
        enforcement: warning
      """,
      "test/sample_test.exs" => """
      defmodule SampleTest do
        use ExUnit.Case

        @tag spec: "a.one"
        test "covers a.one" do
          assert true
        end
      end
      """
    })

    write_subject_spec(
      root,
      "placeholder",
      meta: %{"id" => "placeholder.subject", "kind" => "module", "status" => "active"}
    )

    index = Index.build(root)

    assert is_map(index["test_tags"])
    assert Map.has_key?(index["test_tags"], "a.one")

    assert index["test_tags_config"] == %{
             "enabled" => true,
             "paths" => ["test"],
             "enforcement" => "warning"
           }
  end

  @tag spec: "specled.index.tag_data_conditional"
  test "caller option forces test-tag scanning even when config disables it", %{root: root} do
    write_files(root, %{
      "test/sample_test.exs" => """
      defmodule SampleTest do
        use ExUnit.Case

        @tag spec: "b.two"
        test "covers b.two" do
          assert true
        end
      end
      """
    })

    write_subject_spec(
      root,
      "placeholder",
      meta: %{"id" => "placeholder.subject", "kind" => "module", "status" => "active"}
    )

    index = Index.build(root, test_tags: true)

    assert Map.has_key?(index["test_tags"], "b.two")
    assert index["test_tags_config"]["enabled"] == true
  end

  @tag spec: "specled.index.tag_data_absent_when_disabled"
  test "omits test_tags keys when scanning is disabled", %{root: root} do
    write_subject_spec(
      root,
      "placeholder",
      meta: %{"id" => "placeholder.subject", "kind" => "module", "status" => "active"}
    )

    index = Index.build(root)

    refute Map.has_key?(index, "test_tags")
    refute Map.has_key?(index, "test_tags_errors")
    refute Map.has_key?(index, "test_tags_config")
  end

  @tag spec: "specled.index.tag_data_absent_when_disabled"
  test "caller option disable overrides config", %{root: root} do
    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
      """
    })

    write_subject_spec(
      root,
      "placeholder",
      meta: %{"id" => "placeholder.subject", "kind" => "module", "status" => "active"}
    )

    index = Index.build(root, test_tags: false)

    refute Map.has_key?(index, "test_tags")
    refute Map.has_key?(index, "test_tags_config")
  end
end
