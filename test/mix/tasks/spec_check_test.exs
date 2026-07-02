defmodule Mix.Tasks.Spec.CheckTest do
  # SPECLED_SHOW_INFO env mutation is VM-global.
  use SpecLedEx.Case, async: false

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

defmodule Mix.Tasks.Spec.CheckCommandTimeoutTest do
  use SpecLedEx.Case

  @moduletag :capture_log

  describe "default_context/1 (specled.tasks.check_builds_compile_context)" do
    @tag spec: "specled.tasks.check_builds_compile_context"
    test "returns a context with a non-empty manifest when root is the cwd" do
      context = Mix.Tasks.Spec.Check.default_context(File.cwd!())

      assert %SpecLedEx.Compiler.Context{} = context

      assert map_size(context.manifest) > 0,
             "expected the current project's compile manifest to load non-empty"
    end

    @tag spec: "specled.tasks.check_builds_compile_context"
    test "returns a context for a relative root that expands to the cwd" do
      assert %SpecLedEx.Compiler.Context{} = Mix.Tasks.Spec.Check.default_context(".")
    end

    @tag spec: "specled.tasks.check_builds_compile_context"
    test "returns nil when --root points anywhere else", %{root: root} do
      assert Mix.Tasks.Spec.Check.default_context(root) == nil
    end
  end

  describe "--command-timeout-ms precedence" do
    @tag spec: "specled.verify.command_timeout_cli_precedence"
    test "flag beats config value", %{root: root} do
      write_timeout_config(root, 1)
      marker = write_slow_command_spec(root, "check_cli_timeout")

      Mix.Tasks.Spec.Check.run(["--root", root, "--command-timeout-ms", "5000"])

      assert read_state(root)["summary"]["findings"] == 0
      assert File.read!(Path.join(root, marker)) == "done"
    end

    @tag spec: [
           "specled.verify.command_timeout_cli_precedence",
           "specled.verify.command_timeout_distinct_finding"
         ]
    test "absent flag falls back to config value", %{root: root} do
      write_timeout_config(root, 1)
      write_slow_command_spec(root, "check_config_timeout")

      assert_raise Mix.Error, ~r/Spec check failed: 1 validation finding/, fn ->
        Mix.Tasks.Spec.Check.run(["--root", root])
      end

      assert [%{"code" => "verification_command_timeout", "message" => message}] =
               read_state(root)["findings"]

      assert message =~ "command exceeded 1ms"
      assert message =~ "--command-timeout-ms 2"
    end

    @tag spec: "specled.verify.command_timeout_cli_precedence"
    test "absent flag and config fall back to verifier default", %{root: root} do
      marker = write_slow_command_spec(root, "check_default_timeout")

      Mix.Tasks.Spec.Check.run(["--root", root])

      assert read_state(root)["summary"]["findings"] == 0
      assert File.read!(Path.join(root, marker)) == "done"
    end
  end

  defp write_timeout_config(root, timeout_ms) do
    write_files(root, %{
      ".spec/config.yml" => "verification:\n  command_timeout_ms: #{timeout_ms}\n"
    })
  end

  defp write_slow_command_spec(root, name) do
    marker = "#{name}.txt"
    requirement_id = "#{name}.requirement"

    write_subject_spec(
      root,
      name,
      meta: %{"id" => "#{name}.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => requirement_id,
          "statement" =>
            "Command timeout precedence remains observable through a deliberately slow verification command."
        }
      ],
      verification: [
        %{
          "kind" => "command",
          "target" => "sleep 0.05; printf done > #{marker}",
          "covers" => [requirement_id],
          "execute" => true
        }
      ]
    )

    marker
  end
end
