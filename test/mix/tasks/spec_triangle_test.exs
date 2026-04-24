defmodule Mix.Tasks.SpecTriangleTest do
  # covers: specled.triangulation.spec_triangle_task
  use SpecLedEx.Case
  @moduletag spec: ["specled.triangulation.spec_triangle_task"]

  alias SpecLedEx.Compiler.Tracer

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

    Mix.Tasks.Spec.Triangle.run([
      "--root",
      root,
      "--artifact-path",
      Path.join(root, ".spec/_coverage/missing.coverdata"),
      "demo.subject"
    ])

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

  test "prints source files for closure MFA tuples after rendering closure MFA strings",
       %{root: root} do
    preserve_tracer_manifest(fn ->
      write_subject_spec(
        root,
        "status_subject",
        meta: %{
          "id" => "specled.status",
          "kind" => "workflow",
          "status" => "active",
          "surface" => ["lib/specled_ex/status.ex"],
          "realized_by" => %{
            "implementation" => ["SpecLedEx.Coverage.category_summary/3"]
          }
        },
        requirements: [
          %{
            "id" => "specled.status.coverage_summary",
            "statement" => "Status shall summarize current coverage categories.",
            "priority" => "must"
          }
        ]
      )

      write_tracer_edges(%{{SpecLedEx.Coverage, :category_summary, 3} => []})

      Mix.Tasks.Spec.Triangle.run([
        "--root",
        root,
        "--artifact-path",
        Path.join(root, ".spec/_coverage/missing.coverdata"),
        "specled.status"
      ])

      messages = drain_shell_messages()

      assert message_contains?(
               messages,
               "closure_mfas: SpecLedEx.Coverage.category_summary/3"
             )

      assert message_contains?(messages, "closure_files:")
      assert message_contains?(messages, "lib/specled_ex/coverage.ex")
    end)
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

  test "prints diagnostics for all subjects when no subject id is provided", %{root: root} do
    write_subject_spec(
      root,
      "first_subject",
      meta: %{"id" => "first.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => "first.subject.r1",
          "statement" => "First subject behavior.",
          "priority" => "must"
        }
      ]
    )

    write_subject_spec(
      root,
      "second_subject",
      meta: %{"id" => "second.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => "second.subject.r1",
          "statement" => "Second subject behavior.",
          "priority" => "must"
        }
      ]
    )

    Mix.Tasks.Spec.Triangle.run([
      "--root",
      root,
      "--artifact-path",
      Path.join(root, ".spec/_coverage/missing.coverdata")
    ])

    messages = drain_shell_messages()

    assert message_contains?(messages, "subject: first.subject")
    assert message_contains?(messages, "subject: second.subject")
    assert message_contains?(messages, "first.subject.r1")
    assert message_contains?(messages, "second.subject.r1")
    refute File.exists?(Path.join(root, ".spec/state.json"))
  end

  test "prints diagnostics for all subjects with --all", %{root: root} do
    write_subject_spec(
      root,
      "only_subject",
      meta: %{"id" => "only.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => "only.subject.r1",
          "statement" => "Only subject behavior.",
          "priority" => "must"
        }
      ]
    )

    Mix.Tasks.Spec.Triangle.run([
      "--root",
      root,
      "--artifact-path",
      Path.join(root, ".spec/_coverage/missing.coverdata"),
      "--all"
    ])

    messages = drain_shell_messages()

    assert message_contains?(messages, "subject: only.subject")
    assert message_contains?(messages, "only.subject.r1")
  end

  test "raises when --all is combined with a subject id", %{root: root} do
    assert_raise Mix.Error, ~r/Usage: mix spec.triangle/, fn ->
      Mix.Tasks.Spec.Triangle.run(["--root", root, "--all", "some.subject"])
    end
  end

  defp preserve_tracer_manifest(fun) do
    path = Tracer.manifest_path()
    previous = if File.regular?(path), do: File.read!(path), else: :missing

    try do
      fun.()
    after
      case previous do
        :missing -> File.rm(path)
        binary -> File.write!(path, binary)
      end
    end
  end

  defp write_tracer_edges(edges) do
    path = Tracer.manifest_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(edges))
  end
end
