defmodule Mix.Tasks.Spec.SuggestBindingTest do
  use SpecLedEx.Case

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
