defmodule Mix.Tasks.Spec.SuggestBindingTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.api_boundary.suggest_binding_proposal_only"]

  setup do
    Mix.Task.reenable("spec.suggest_binding")
    :ok
  end

  describe "mix spec.suggest_binding" do
    test "prints a YAML realized_by: proposal for subjects with no binding", %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "example",
        meta: %{
          "id" => "example.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/example/foo.ex", "lib/example/bar.ex"]
        },
        requirements: [
          %{"id" => "example.req", "statement" => "something", "priority" => "must"}
        ]
      )

      commit_all(root, "seed")

      Mix.Tasks.Spec.SuggestBinding.run(["--root", root])

      messages = drain_shell_messages()
      joined = Enum.join(messages, "\n")

      assert String.contains?(joined, "realized_by:"),
             "expected 'realized_by:' in output, got:\n#{joined}"

      assert String.contains?(joined, "api_boundary:")
      assert String.contains?(joined, "Example.Foo")
      assert String.contains?(joined, "Example.Bar")
      assert String.contains?(joined, "example.subject")
    end

    test "exits 0 (no raise) when run on subjects without bindings and no --fail-on-missing",
         %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "nobind",
        meta: %{
          "id" => "nobind.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/nobind.ex"]
        },
        requirements: [
          %{"id" => "nobind.req", "statement" => "x", "priority" => "must"}
        ]
      )

      commit_all(root, "seed")

      # Should not raise
      assert :ok = Mix.Tasks.Spec.SuggestBinding.run(["--root", root])
    end

    test "writes nothing to disk (proposal-only)", %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "nowrite",
        meta: %{
          "id" => "nowrite.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/nowrite.ex"]
        },
        requirements: [%{"id" => "nowrite.req", "statement" => "x", "priority" => "must"}]
      )

      commit_all(root, "seed")

      before_files = all_files_in(root)
      Mix.Tasks.Spec.SuggestBinding.run(["--root", root])
      after_files = all_files_in(root)

      assert before_files == after_files,
             "task wrote files: #{inspect(after_files -- before_files)}"

      # Specifically, the spec file content is unchanged
      spec_path = Path.join(root, ".spec/specs/nowrite.spec.md")
      refute File.read!(spec_path) =~ "realized_by:"
    end

    test "no --write flag accepted (exits clean; flag is unknown so OptionParser drops it)",
         %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "flagtest",
        meta: %{
          "id" => "flagtest.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/flagtest.ex"]
        }
      )

      commit_all(root, "seed")

      # --write is not a recognized flag; OptionParser:strict rejects it.
      # The current task only accepts --root and --fail-on-missing.
      strict_keys =
        Mix.Tasks.Spec.SuggestBinding.module_info(:compile)[:source]
        |> to_string()
        |> File.read!()

      refute strict_keys =~ ~r/write:\s*:(string|boolean)/,
             "spec.suggest_binding must not accept --write per scope cut #21"
    end

    test "--fail-on-missing raises when any subject is unbound", %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "missing",
        meta: %{
          "id" => "missing.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/missing.ex"]
        }
      )

      commit_all(root, "seed")

      assert_raise Mix.Error, ~r/missing realized_by/, fn ->
        Mix.Tasks.Spec.SuggestBinding.run(["--root", root, "--fail-on-missing"])
      end
    end

    test "camelizes dotted Mix task filenames into valid module names", %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "dotted",
        meta: %{
          "id" => "dotted.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => [
            "lib/mix/tasks/foo.bar_baz.ex",
            "lib/mix/tasks/spec.cover.test.ex"
          ]
        },
        requirements: [
          %{"id" => "dotted.req", "statement" => "x", "priority" => "must"}
        ]
      )

      commit_all(root, "seed")

      Mix.Tasks.Spec.SuggestBinding.run(["--root", root])

      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "Mix.Tasks.Foo.BarBaz"),
             "expected 'Mix.Tasks.Foo.BarBaz' in output, got:\n#{joined}"

      assert String.contains?(joined, "Mix.Tasks.Spec.Cover.Test"),
             "expected 'Mix.Tasks.Spec.Cover.Test' in output, got:\n#{joined}"

      refute String.contains?(joined, "Mix.Tasks.foo.barBaz"),
             "stale camelize bug still present; got:\n#{joined}"

      refute String.contains?(joined, "Mix.Tasks.Spec.cover.test"),
             "stale camelize bug still present; got:\n#{joined}"
    end

    test "resolves the real defmodule name from source instead of camelizing the path",
         %{root: root} do
      init_git_repo(root)

      # Real module name does NOT match a naive camelize of the path
      # (acronym) — and the path has a segment the module name omits.
      File.mkdir_p!(Path.join(root, "lib/example/web/channels"))

      File.write!(Path.join(root, "lib/example/llm_extractor.ex"), """
      defmodule Example.LLMExtractor do
        @moduledoc false
      end
      """)

      File.write!(Path.join(root, "lib/example/web/channels/terminal_channel.ex"), """
      defmodule ExampleWeb.TerminalChannel do
        @moduledoc false
      end
      """)

      write_subject_spec(root, "real",
        meta: %{
          "id" => "real.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => [
            "lib/example/llm_extractor.ex",
            "lib/example/web/channels/terminal_channel.ex"
          ]
        },
        requirements: [%{"id" => "real.req", "statement" => "x", "priority" => "must"}]
      )

      commit_all(root, "seed")

      Mix.Tasks.Spec.SuggestBinding.run(["--root", root])
      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "Example.LLMExtractor"),
             "expected real defmodule name, got:\n#{joined}"

      assert String.contains?(joined, "ExampleWeb.TerminalChannel"),
             "expected real defmodule name from source, got:\n#{joined}"

      refute String.contains?(joined, "Example.LlmExtractor"),
             "still camelizing the path instead of reading the module:\n#{joined}"

      refute String.contains?(joined, "Example.Web.Channels.TerminalChannel"),
             "still deriving namespace from the path instead of the module:\n#{joined}"
    end

    test "falls back to the path-derived name when the surface file is absent",
         %{root: root} do
      init_git_repo(root)

      # No lib/absent/thing.ex on disk — proposal should still be produced via
      # the path-camelize fallback.
      write_subject_spec(root, "absent",
        meta: %{
          "id" => "absent.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/absent/thing.ex"]
        },
        requirements: [%{"id" => "absent.req", "statement" => "x", "priority" => "must"}]
      )

      commit_all(root, "seed")

      Mix.Tasks.Spec.SuggestBinding.run(["--root", root])
      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "Absent.Thing"),
             "expected path-derived fallback name, got:\n#{joined}"
    end

    test "does not print a proposal for subjects that already have realized_by", %{root: root} do
      init_git_repo(root)

      path =
        write_spec(
          root,
          "bound",
          """
          # Bound

          ```spec-meta
          id: bound.subject
          kind: module
          status: active
          realized_by:
            api_boundary:
              - "Some.Mod.foo/1"
          ```

          ```spec-requirements
          - id: bound.req
            statement: x
            priority: must
          ```
          """
        )

      assert File.exists?(path)
      commit_all(root, "seed")

      Mix.Tasks.Spec.SuggestBinding.run(["--root", root])

      messages = drain_shell_messages()
      joined = Enum.join(messages, "\n")

      refute String.contains?(joined, "bound.subject")
    end
  end

  defp all_files_in(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&String.contains?(&1, "/.git/"))
    |> Enum.sort()
  end
end
