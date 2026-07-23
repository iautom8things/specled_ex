defmodule Mix.Tasks.Spec.ConfigDiagnosticsTest do
  use SpecLedEx.Case

  @moduletag spec: ["specled.tasks.config_diagnostics_surfaced"]

  @moduletag :capture_log

  # A `.spec/config.yml` severity written in YAML atom form (`:off`) is read as
  # the string ":off", which no severity token matches, so Config.load drops the
  # entry and records a config_warning diagnostic. Both tasks must surface it.
  @invalid_config """
  branch_guard:
    severities:
      branch_guard_dangling_binding: :off
  """

  # `off` as a bareword is a valid severity token, so this control config parses
  # cleanly and records no diagnostics.
  @valid_config """
  branch_guard:
    severities:
      branch_guard_dangling_binding: off
  """

  describe "mix spec.validate surfaces config diagnostics" do
    @tag spec: "specled.tasks.config_diagnostics_surfaced"
    test "prints a [CONFIG] warning for a dropped invalid severity", %{root: root} do
      scaffold_passing_subject(root)
      write_config(root, @invalid_config)

      Mix.Tasks.Spec.Validate.run(["--root", root])

      assert config_warning_line(drain_shell_messages()) =~
               "branch_guard.severities.branch_guard_dangling_binding must be one of"
    end

    @tag spec: "specled.tasks.config_diagnostics_surfaced"
    test "prints no [CONFIG] line when the config is valid", %{root: root} do
      scaffold_passing_subject(root)
      write_config(root, @valid_config)

      Mix.Tasks.Spec.Validate.run(["--root", root])

      refute Enum.any?(drain_shell_messages(), &String.contains?(&1, "[CONFIG]"))
    end
  end

  describe "mix spec.check surfaces config diagnostics" do
    @tag spec: "specled.tasks.config_diagnostics_surfaced"
    test "prints a [CONFIG] warning for a dropped invalid severity", %{root: root} do
      scaffold_committed_workspace(root, @invalid_config)

      run_spec_check(root)

      assert config_warning_line(drain_shell_messages()) =~
               "branch_guard.severities.branch_guard_dangling_binding must be one of"
    end

    @tag spec: "specled.tasks.config_diagnostics_surfaced"
    test "prints no [CONFIG] line when the config is valid", %{root: root} do
      scaffold_committed_workspace(root, @valid_config)

      run_spec_check(root)

      refute Enum.any?(drain_shell_messages(), &String.contains?(&1, "[CONFIG]"))
    end
  end

  defp config_warning_line(messages) do
    Enum.find(messages, "", &String.contains?(&1, "[CONFIG]"))
  end

  defp write_config(root, yaml) do
    write_files(root, %{".spec/config.yml" => yaml})
  end

  defp scaffold_passing_subject(root) do
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
  end

  defp scaffold_committed_workspace(root, config_yaml) do
    init_git_repo(root)
    write_files(root, %{"README.md" => "# Bootstrap\n"})
    commit_all(root, "initial without spec workspace")

    scaffold_passing_subject(root)
    write_config(root, config_yaml)

    index = SpecLedEx.index(root)
    SpecLedEx.write_state(index, nil, root)
    commit_all(root, "add spec, config, and state.json")
  end

  # spec.check flips to a Mix.Error exit when the branch guard finds issues; the
  # config diagnostics are emitted before that, so treat the raise as a
  # successful run for the purpose of inspecting the printed output.
  defp run_spec_check(root) do
    Mix.Tasks.Spec.Check.run(["--root", root, "--base", "HEAD"])
  rescue
    e in Mix.Error ->
      _ = e
      :ok
  end
end
