defmodule Mix.Tasks.SpecTriangleTest do
  # covers: specled.triangulation.spec_triangle_task
  use SpecLedEx.Case

  test "prints per-requirement diagnostic for a known subject without mutating state.json",
       %{root: root} do
    write_subject_spec(
      root,
      "demo_subject",
      meta: %{
        "id" => "demo.subject",
        "kind" => "module",
        "status" => "active",
        "surface" => ["lib/demo.ex"]
      },
      requirements: [
        %{
          "id" => "demo.subject.requirement_one",
          "statement" => "The demo subject shall emit a result.",
          "priority" => "must"
        }
      ]
    )

    Mix.Tasks.Spec.Triangle.run(["--root", root, "demo.subject"])

    messages = drain_shell_messages()

    assert message_contains?(messages, "subject: demo.subject")
    assert message_contains?(messages, "demo.subject.requirement_one")
    assert message_contains?(messages, "effective_binding:")
    assert message_contains?(messages, "execution_reach:")
    # Coverage artifact is missing in the isolated tmp root — graceful note.
    assert message_contains?(messages, "coverage artifact missing")

    # Read-only: state.json must not exist after the task runs (per
    # specled.triangulation.spec_triangle_task).
    refute File.exists?(Path.join(root, ".spec/state.json"))
  end

  test "raises on unknown subject", %{root: root} do
    write_subject_spec(
      root,
      "known_subject",
      meta: %{"id" => "known.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "known.subject.r1", "statement" => "A thing.", "priority" => "must"}
      ]
    )

    assert_raise Mix.Error, ~r/Unknown subject/, fn ->
      Mix.Tasks.Spec.Triangle.run(["--root", root, "does.not.exist"])
    end
  end

  test "raises when no subject id is provided", %{root: root} do
    assert_raise Mix.Error, ~r/Usage: mix spec.triangle/, fn ->
      Mix.Tasks.Spec.Triangle.run(["--root", root])
    end
  end
end
