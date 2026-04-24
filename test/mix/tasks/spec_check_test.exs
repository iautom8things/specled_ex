defmodule Mix.Tasks.Spec.CheckTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.tasks.check_verbose_flag"]

  @moduletag :capture_log

  describe "--verbose flag and SPECLED_SHOW_INFO filter :info findings on stdout" do
    @tag spec: "specled.tasks.check_verbose_flag"
    test "default run suppresses :info branch findings from stdout", %{root: root} do
      scaffold_no_baseline_fixture(root)

      run_spec_check(root, ["--base", "HEAD~1"])

      messages = drain_shell_messages()

      refute Enum.any?(messages, fn msg ->
               String.contains?(msg, "[INFO]") and
                 String.contains?(msg, "append_only/no_baseline")
             end),
             "default stdout must not print :info findings; got: " <> inspect(messages)
    end

    @tag spec: "specled.tasks.check_verbose_flag"
    test "--verbose prints :info findings on stdout", %{root: root} do
      scaffold_no_baseline_fixture(root)

      run_spec_check(root, ["--base", "HEAD~1", "--verbose"])

      messages = drain_shell_messages()

      assert Enum.any?(messages, fn msg ->
               String.contains?(msg, "[INFO]") and
                 String.contains?(msg, "append_only/no_baseline")
             end),
             "--verbose must print [INFO] append_only/no_baseline on stdout; got: " <>
               inspect(messages)
    end

    @tag spec: "specled.tasks.check_verbose_flag"
    test "SPECLED_SHOW_INFO=1 has the same effect as --verbose", %{root: root} do
      scaffold_no_baseline_fixture(root)

      System.put_env("SPECLED_SHOW_INFO", "1")

      try do
        run_spec_check(root, ["--base", "HEAD~1"])
      after
        System.delete_env("SPECLED_SHOW_INFO")
      end

      messages = drain_shell_messages()

      assert Enum.any?(messages, fn msg ->
               String.contains?(msg, "[INFO]") and
                 String.contains?(msg, "append_only/no_baseline")
             end),
             "SPECLED_SHOW_INFO=1 must un-filter :info findings; got: " <> inspect(messages)
    end

    @tag spec: "specled.tasks.check_verbose_flag"
    test "state.json written by spec.validate is unaffected by --verbose", %{root: root} do
      # The --verbose flag only gates stdout printing. The state.json produced
      # by the validate step must be identical whether or not --verbose is set.
      scaffold_no_baseline_fixture(root)

      run_spec_check(root, ["--base", "HEAD~1"])
      default_state = read_state(root)
      Mix.Shell.Process.flush()

      run_spec_check(root, ["--base", "HEAD~1", "--verbose"])
      verbose_state = read_state(root)

      assert default_state == verbose_state,
             "state.json must not differ based on --verbose; diff at keys: " <>
               inspect(diff_keys(default_state, verbose_state))
    end
  end

  defp scaffold_no_baseline_fixture(root) do
    init_git_repo(root)

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => "billing.invoice",
          "statement" => "The system MUST emit an invoice on every charge.",
          "priority" => "must"
        }
      ],
      verification: [
        %{
          "kind" => "source_file",
          "target" => ".spec/specs/billing.spec.md",
          "covers" => ["billing.invoice"]
        }
      ]
    )

    commit_all(root, "initial spec, no state.json")

    index = SpecLedEx.index(root)
    SpecLedEx.write_state(index, nil, root)
    commit_all(root, "add state.json")
  end

  # Runs mix spec.check and treats an expected Mix.Error (when findings flip
  # the branch status to fail) as success for the purposes of inspecting the
  # printed output. Stdout-filter behavior is orthogonal to exit status.
  defp run_spec_check(root, extra_args) do
    Mix.Task.reenable("spec.check")

    try do
      Mix.Tasks.Spec.Check.run(["--root", root | extra_args])
    rescue
      e in Mix.Error ->
        _ = e
        :ok
    end
  end

  defp diff_keys(left, right) when is_map(left) and is_map(right) do
    all_keys = (Map.keys(left) ++ Map.keys(right)) |> Enum.uniq()
    Enum.filter(all_keys, &(Map.get(left, &1) != Map.get(right, &1)))
  end

  defp diff_keys(_, _), do: [:not_both_maps]
end
