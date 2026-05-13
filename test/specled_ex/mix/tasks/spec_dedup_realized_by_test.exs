defmodule Mix.Tasks.Spec.DedupRealizedByTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.tasks.dedup_realized_by_proposal",
               "specled.tasks.dedup_realized_by_no_write",
               "specled.tasks.dedup_realized_by_exit_code",
               "specled.tasks.dedup_realized_by_shared_seam"
             ]

  setup do
    Mix.Task.reenable("spec.dedup_realized_by")
    :ok
  end

  describe "mix spec.dedup_realized_by — proposal block format" do
    @tag spec: "specled.tasks.dedup_realized_by_proposal"
    test "prints a YAML proposal block per subject with cross-tier duplicates", %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "alpha", "alpha.subject", %{
        "api_boundary" => ["Mod.a/1", "Mod.b/2"],
        "implementation" => ["Mod.a/1", "Mod.b/2"]
      })

      commit_all(root, "seed")

      Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])

      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "alpha.subject"),
             "expected subject id in proposal, got:\n#{joined}"

      assert String.contains?(joined, "realized_by:")
      assert String.contains?(joined, "api_boundary:")
      assert String.contains?(joined, "Mod.a/1")
      assert String.contains?(joined, "Mod.b/2")
    end

    @tag spec: "specled.tasks.dedup_realized_by_proposal"
    test "each removal line carries the '# already implied by implementation' comment",
         %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "comment", "comment.subject", %{
        "api_boundary" => ["Mod.a/1"],
        "implementation" => ["Mod.a/1"]
      })

      commit_all(root, "seed")

      Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])

      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "# already implied by implementation"),
             "expected '# already implied by implementation' on removal, got:\n#{joined}"

      # The comment must be on the same line as the removal entry, not on its own line.
      removal_line =
        joined
        |> String.split("\n")
        |> Enum.find(fn line -> String.contains?(line, "Mod.a/1") end)

      assert removal_line, "expected to find a line containing the removed entry"

      assert String.contains?(removal_line, "# already implied by implementation"),
             "expected the comment on the removal line, got: #{inspect(removal_line)}"
    end

    @tag spec: "specled.tasks.dedup_realized_by_proposal"
    test "renders one proposal block per subject when multiple subjects have duplicates",
         %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "beta", "beta.subject", %{
        "api_boundary" => ["B.b/1"],
        "implementation" => ["B.b/1"]
      })

      write_subject_with_realized_by(root, "alpha", "alpha.subject", %{
        "api_boundary" => ["A.a/1"],
        "implementation" => ["A.a/1"]
      })

      commit_all(root, "seed")

      Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])

      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "alpha.subject")
      assert String.contains?(joined, "beta.subject")

      # Subjects are emitted in deterministic (sorted by subject id) order so
      # the output is diff-stable across runs.
      alpha_idx = :binary.match(joined, "alpha.subject") |> elem(0)
      beta_idx = :binary.match(joined, "beta.subject") |> elem(0)

      assert alpha_idx < beta_idx,
             "expected alpha.subject before beta.subject (sorted), got:\n#{joined}"
    end
  end

  describe "mix spec.dedup_realized_by — exit code semantics" do
    @tag spec: "specled.tasks.dedup_realized_by_exit_code"
    test "exits 0 by default even when duplicates are found", %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "dup", "dup.subject", %{
        "api_boundary" => ["Mod.a/1"],
        "implementation" => ["Mod.a/1"]
      })

      commit_all(root, "seed")

      assert :ok = Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])
    end

    @tag spec: "specled.tasks.dedup_realized_by_exit_code"
    test "exits 0 cleanly when no duplications are found", %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "clean", "clean.subject", %{
        "api_boundary" => ["A.a/1"],
        "implementation" => ["B.b/2"]
      })

      commit_all(root, "seed")

      assert :ok = Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])

      joined = drain_shell_messages() |> Enum.join("\n")

      assert String.contains?(joined, "No realized_by duplications found."),
             "expected clean-exit message, got:\n#{joined}"
    end

    @tag spec: "specled.tasks.dedup_realized_by_exit_code"
    test "--fail-on-dups raises when any subject has at least one duplication",
         %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "dup", "dup.subject", %{
        "api_boundary" => ["Mod.a/1"],
        "implementation" => ["Mod.a/1"]
      })

      commit_all(root, "seed")

      assert_raise Mix.Error, ~r/realized_by duplications/, fn ->
        Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root, "--fail-on-dups"])
      end
    end

    @tag spec: "specled.tasks.dedup_realized_by_exit_code"
    test "--fail-on-dups still exits 0 when no subject has duplicates", %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "clean", "clean.subject", %{
        "api_boundary" => ["A.a/1"],
        "implementation" => ["B.b/2"]
      })

      commit_all(root, "seed")

      assert :ok = Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root, "--fail-on-dups"])
    end
  end

  describe "mix spec.dedup_realized_by — no --write flag" do
    @tag spec: "specled.tasks.dedup_realized_by_no_write"
    test "the task source does not declare a --write option", %{root: _root} do
      source =
        Mix.Tasks.Spec.DedupRealizedBy.module_info(:compile)[:source]
        |> to_string()
        |> File.read!()

      refute source =~ ~r/write:\s*:(string|boolean)/,
             "spec.dedup_realized_by must not accept --write per " <>
               "specled.tasks.dedup_realized_by_no_write"
    end

    @tag spec: "specled.tasks.dedup_realized_by_no_write"
    test "writes nothing to disk (proposal-only)", %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "nowrite", "nowrite.subject", %{
        "api_boundary" => ["Mod.a/1"],
        "implementation" => ["Mod.a/1"]
      })

      commit_all(root, "seed")

      before_files = all_files_in(root)
      Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])
      after_files = all_files_in(root)

      assert before_files == after_files,
             "task wrote files: #{inspect(after_files -- before_files)}"
    end
  end

  describe "mix spec.dedup_realized_by — shared seam with validator" do
    @tag spec: "specled.tasks.dedup_realized_by_shared_seam"
    test "the task computes duplications via RealizedByDedupe.duplicates/1",
         %{root: _root} do
      source =
        Mix.Tasks.Spec.DedupRealizedBy.module_info(:compile)[:source]
        |> to_string()
        |> File.read!()

      assert source =~ "RealizedByDedupe.duplicates",
             "task must call RealizedByDedupe.duplicates/1 (the shared seam) " <>
               "per specled.tasks.dedup_realized_by_shared_seam"
    end

    @tag spec: "specled.tasks.dedup_realized_by_shared_seam"
    test "task and validator agree: same duplicate set is reported by both surfaces",
         %{root: root} do
      init_git_repo(root)

      write_subject_with_realized_by(root, "agree", "agree.subject", %{
        "api_boundary" => ["Mod.a/1", "Mod.b/2"],
        "implementation" => ["Mod.a/1", "Mod.b/2"]
      })

      commit_all(root, "seed")

      # Build the index the same way the task does.
      spec_dir = SpecLedEx.detect_spec_dir(root)
      authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
      index = SpecLedEx.index(root, spec_dir: spec_dir, authored_dir: authored_dir)

      validator_entries =
        SpecLedEx.Validator.RealizedByDedupCheck.findings(index)
        |> Enum.map(& &1["message"])
        |> Enum.flat_map(fn msg ->
          # Extract the entry name embedded in the validator message.
          cond do
            String.contains?(msg, "Mod.a/1") -> ["Mod.a/1"]
            String.contains?(msg, "Mod.b/2") -> ["Mod.b/2"]
            true -> []
          end
        end)
        |> Enum.sort()

      Mix.Tasks.Spec.DedupRealizedBy.run(["--root", root])

      task_output = drain_shell_messages() |> Enum.join("\n")

      task_entries =
        ["Mod.a/1", "Mod.b/2"]
        |> Enum.filter(&String.contains?(task_output, &1))
        |> Enum.sort()

      assert validator_entries == task_entries,
             "shared seam should produce identical entry sets; " <>
               "validator=#{inspect(validator_entries)} task=#{inspect(task_entries)}"
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp write_subject_with_realized_by(root, name, id, realized_by) do
    write_spec(
      root,
      name,
      """
      # #{Macro.camelize(name)}

      ```spec-meta
      #{render_meta_yaml(id, realized_by)}
      ```

      ```spec-requirements
      - id: #{name}.req
        statement: x
        priority: must
      ```
      """
    )
  end

  defp render_meta_yaml(id, realized_by) do
    realized_by_lines =
      realized_by
      |> Enum.flat_map(fn {tier, entries} ->
        ["  #{tier}:"] ++ Enum.map(entries, fn e -> "    - \"#{e}\"" end)
      end)
      |> Enum.join("\n")

    """
    id: #{id}
    kind: module
    status: active
    realized_by:
    #{realized_by_lines}
    """
    |> String.trim_trailing()
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
