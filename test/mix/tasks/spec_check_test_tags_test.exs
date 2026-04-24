defmodule Mix.Tasks.Spec.CheckTestTagsTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.tasks.test_tags_flag", "specled.tasks.test_tags_precedence"]

  @moduletag :capture_log

  @tag spec: "specled.tasks.test_tags_flag"
  test "--test-tags forces scanning even when config disables it", %{root: root} do
    scaffold_with_untagged_requirement(root)

    write_files(root, %{
      ".spec/config.yml" => "test_tags:\n  enabled: false\n"
    })

    Mix.Tasks.Spec.Validate.run(["--root", root, "--test-tags"])

    assert findings_have_code?(root, "requirement_without_test_tag")
  end

  @tag spec: "specled.tasks.test_tags_flag"
  test "--no-test-tags disables scanning even when config enables it", %{root: root} do
    scaffold_with_untagged_requirement(root)

    write_files(root, %{
      ".spec/config.yml" => "test_tags:\n  enabled: true\n"
    })

    Mix.Tasks.Spec.Validate.run(["--root", root, "--no-test-tags"])

    refute findings_have_code?(root, "requirement_without_test_tag")
  end

  @tag spec: "specled.tasks.test_tags_precedence"
  test "config value is used when no CLI flag is passed", %{root: root} do
    scaffold_with_untagged_requirement(root)

    write_files(root, %{
      ".spec/config.yml" => "test_tags:\n  enabled: true\n  paths:\n    - test\n"
    })

    Mix.Tasks.Spec.Validate.run(["--root", root])

    assert findings_have_code?(root, "requirement_without_test_tag")
  end

  @tag spec: "specled.tasks.test_tags_precedence"
  test "built-in default disables scanning when neither CLI nor config supply a value", %{
    root: root
  } do
    scaffold_with_untagged_requirement(root)

    Mix.Tasks.Spec.Validate.run(["--root", root])

    refute findings_have_code?(root, "requirement_without_test_tag")
  end

  defp scaffold_with_untagged_requirement(root) do
    write_subject_spec(
      root,
      "placeholder",
      meta: %{"id" => "placeholder.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "placeholder.must", "statement" => "Required", "priority" => "must"}
      ],
      verification: [
        %{
          "kind" => "tagged_tests",
          "covers" => ["placeholder.must"],
          "execute" => true
        }
      ]
    )
  end

  defp findings_have_code?(root, code) do
    state = read_state(root)
    Enum.any?(state["findings"] || [], &(&1["code"] == code))
  end
end
