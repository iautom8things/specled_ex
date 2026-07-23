defmodule Mix.Tasks.SpecTriangleTest do
  # covers: specled.triangulation.spec_triangle_task
  # Tracer.manifest_path/0 points at a shared _build manifest file.
  use SpecLedEx.Case, async: false

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

  defp write_envelope_term(path, term) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(term))
  end

  # covers: specled.triangulation.spec_triangle_task
  describe "v2 envelope: mode + closure-coverage % + detector_unavailable labeling" do
    test "aggregate mode prints \"mode: aggregate\", per-requirement closure_coverage, and labels per-test detectors detector_unavailable",
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

        artifact_path = Path.join(root, ".spec/_coverage/per_test.coverdata")

        write_envelope_term(artifact_path, %{
          version: 2,
          mode: :aggregate,
          generated_at: ~U[2026-07-23 00:00:00Z],
          source: "test.coverdata",
          files: [],
          mfas: [%{mfa: "SpecLedEx.Coverage.category_summary/3", covered: true}],
          payload: %{unmapped_modules: 0},
          degraded: false
        })

        Mix.Tasks.Spec.Triangle.run([
          "--root",
          root,
          "--artifact-path",
          artifact_path,
          "specled.status"
        ])

        messages = drain_shell_messages()

        assert message_contains?(messages, "mode: aggregate")
        assert message_contains?(messages, "closure_coverage: 1/1 MFAs executed")
        assert message_contains?(messages, "detector_unavailable: aggregate_artifact_only")
      end)
    end

    test "a missing artifact still prints the pre-v2 \"coverage artifact missing\" note", %{
      root: root
    } do
      write_subject_spec(
        root,
        "demo_subject",
        meta: %{"id" => "demo.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "demo.subject.r1", "statement" => "A thing.", "priority" => "must"}
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

      refute message_contains?(messages, "mode:")
      assert message_contains?(messages, "coverage artifact missing; run `mix spec.cover.test`")
      assert message_contains?(messages, "detector_unavailable: no_coverage_artifact")
    end

    test "a legacy (pre-v2) artifact prints a distinct note naming mix spec.cover.test", %{
      root: root
    } do
      write_subject_spec(
        root,
        "demo_subject",
        meta: %{"id" => "demo.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "demo.subject.r1", "statement" => "A thing.", "priority" => "must"}
        ]
      )

      artifact_path = Path.join(root, ".spec/_coverage/per_test.coverdata")
      write_envelope_term(artifact_path, [])

      Mix.Tasks.Spec.Triangle.run([
        "--root",
        root,
        "--artifact-path",
        artifact_path,
        "demo.subject"
      ])

      messages = drain_shell_messages()

      assert message_contains?(messages, "note: coverage artifact is a legacy (pre-v2) format")
      assert message_contains?(messages, "mix spec.cover.test")
      assert message_contains?(messages, "detector_unavailable: legacy_artifact")
      refute message_contains?(messages, "coverage artifact missing")
    end

    test "an invalid/undecodable artifact prints its own distinct note", %{root: root} do
      write_subject_spec(
        root,
        "demo_subject",
        meta: %{"id" => "demo.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "demo.subject.r1", "statement" => "A thing.", "priority" => "must"}
        ]
      )

      artifact_path = Path.join(root, ".spec/_coverage/per_test.coverdata")
      File.mkdir_p!(Path.dirname(artifact_path))
      File.write!(artifact_path, "not a valid erlang term")

      Mix.Tasks.Spec.Triangle.run([
        "--root",
        root,
        "--artifact-path",
        artifact_path,
        "demo.subject"
      ])

      messages = drain_shell_messages()

      assert message_contains?(messages, "note: coverage artifact is invalid or undecodable")
      assert message_contains?(messages, "detector_unavailable: invalid_artifact")
      refute message_contains?(messages, "legacy")
    end

    test "a degraded (async-contaminated) per_test envelope prints a distinct note instead of computing findings",
         %{root: root} do
      write_subject_spec(
        root,
        "demo_subject",
        meta: %{"id" => "demo.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "demo.subject.r1", "statement" => "A thing.", "priority" => "must"}
        ]
      )

      artifact_path = Path.join(root, ".spec/_coverage/per_test.coverdata")

      write_envelope_term(artifact_path, %{
        version: 2,
        mode: :per_test,
        generated_at: ~U[2026-07-23 00:00:00Z],
        source: "test.coverdata",
        files: [],
        mfas: [],
        payload: [],
        degraded: true
      })

      Mix.Tasks.Spec.Triangle.run([
        "--root",
        root,
        "--artifact-path",
        artifact_path,
        "demo.subject"
      ])

      messages = drain_shell_messages()

      assert message_contains?(messages, "mode: per_test")
      assert message_contains?(messages, "note: per-test coverage is degraded")
      assert message_contains?(messages, "detector_unavailable: async_contaminated")
    end

    test "a non-degraded per_test envelope reuses the v1 per-test diagnostic unchanged", %{
      root: root
    } do
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

        source =
          SpecLedEx.Coverage.module_info(:compile)[:source] |> List.to_string()

        records = [
          %{
            test_id: "T.t1",
            file: source,
            lines_hit: [1],
            tags: %{file: "test/a_test.exs", test: "t1"},
            test_pid: self()
          }
        ]

        artifact_path = Path.join(root, ".spec/_coverage/per_test.coverdata")

        write_envelope_term(artifact_path, %{
          version: 2,
          mode: :per_test,
          generated_at: ~U[2026-07-23 00:00:00Z],
          source: "test.coverdata",
          files: [],
          mfas: [],
          payload: records,
          degraded: false
        })

        Mix.Tasks.Spec.Triangle.run([
          "--root",
          root,
          "--artifact-path",
          artifact_path,
          "specled.status"
        ])

        messages = drain_shell_messages()

        assert message_contains?(messages, "mode: per_test")
        refute message_contains?(messages, "n/a (coverage missing)")
        refute message_contains?(messages, "detector_unavailable")
      end)
    end
  end
end
