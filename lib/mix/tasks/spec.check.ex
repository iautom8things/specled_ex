defmodule Mix.Tasks.Spec.Check do
  use Mix.Task

  @requirements ["app.config"]

  alias SpecLedEx.Compiler.Context
  alias SpecLedEx.Config
  alias SpecLedEx.Evidence.{Entry, Store, TreeHash}
  alias SpecLedEx.VerificationStrength

  @shortdoc "Runs the full local Spec Led gate"
  @moduledoc """
  Runs `mix spec.index`, strict `mix spec.validate`, and the branch guard in one command.

  `mix spec.check` enables command execution by default. Use `--no-run-commands`
  to keep command verifications structural-only for a given run.

  After the strict local gate completes, `mix spec.check` writes a local
  evidence attestation to `refs/heads/spec-evidence`. This side effect uses
  Git plumbing only, performs zero network I/O, never checks out the evidence
  ref, and emits a warning without changing the task exit status if the local
  write fails.

  ## Options

    * `--no-run-commands` - skip executing `kind: command` verifications
    * `--min-strength claimed|linked|executed` - require a minimum verification strength
    * `--command-timeout-ms <ms>` - override the command verification timeout
      for this run. Precedence is CLI flag, then `.spec/config.yml`
      `verification.command_timeout_ms`, then the verifier's 120 second default.
    * `--base <ref>` - compare the current branch against the given Git base
    * `--test-tags` / `--no-test-tags` - enable or disable test-tag scanning
      for this invocation, overriding `.spec/config.yml`
    * `--verbose` - print findings of every severity including `:info`. Without
      this flag, `:info`-severity findings are suppressed from stdout.
      `SPECLED_SHOW_INFO=1` in the environment has the same effect as
      `--verbose`.
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          root: :string,
          spec_dir: :string,
          debug: :boolean,
          run_commands: :boolean,
          base: :string,
          min_strength: :string,
          command_timeout_ms: :integer,
          test_tags: :boolean,
          verbose: :boolean
        ],
        aliases: [r: :root, o: :output, d: :debug]
      )

    SpecLedEx.TaskArgs.validate!("spec.check", rest, invalid)

    min_strength = validate_min_strength!(opts[:min_strength])
    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    config = Config.load(root, path: config_path(root, spec_dir))
    emit_config_diagnostics(config)
    command_timeout_ms = opts[:command_timeout_ms] || config.verification.command_timeout_ms
    verification_severities = config.verification.severities
    debug? = opts[:debug] || false
    run_commands? = run_commands?(opts)
    verbose? = verbose?(opts)

    index_opts =
      [spec_dir: spec_dir, authored_dir: authored_dir, config: config]
      |> maybe_put_test_tags(opts)

    index = SpecLedEx.index(root, index_opts)

    Mix.shell().info(
      "authored_dir=#{index["authored_dir"]} subjects=#{index["summary"]["subjects"]} requirements=#{index["summary"]["requirements"]}"
    )

    report =
      SpecLedEx.validate(index, root,
        strict: true,
        debug: debug?,
        run_commands: run_commands?,
        command_timeout_ms: command_timeout_ms,
        severities: verification_severities,
        min_strength: min_strength
      )

    summary = report["summary"]

    Mix.shell().info(
      "status=#{report["status"]} errors=#{summary["errors"]} warnings=#{summary["warnings"]}"
    )

    if debug? do
      print_debug_checks(report["checks"] || [])
    end

    if report["status"] == "fail" do
      print_validation_findings(report["findings"] || [], verbose?)
      Mix.raise("Spec check failed: #{length(report["findings"] || [])} validation finding(s)")
    end

    branch_report =
      SpecLedEx.branch_check(index, root, base: opts[:base], context: default_context(root))

    print_branch_report(branch_report, verbose?)

    if branch_report["status"] == "fail" do
      Mix.raise("Spec check failed: #{length(branch_report["findings"] || [])} branch finding(s)")
    end

    record_evidence(root, report, branch_report)
  end

  # covers: specled.tasks.check_builds_compile_context
  #
  # Compile context for the realization tiers. Mix.Project describes the
  # project in the current working directory, so a `--root` pointing anywhere
  # else gets no context (the pre-wiring behavior) rather than a wrong one —
  # this also keeps tmp-root task tests context-free by construction.
  @doc false
  @spec default_context(Path.t()) :: Context.t() | nil
  def default_context(root) do
    if Path.expand(root) == File.cwd!() do
      Context.from_mix_project()
    else
      nil
    end
  end

  defp maybe_put_test_tags(index_opts, task_opts) do
    case Keyword.fetch(task_opts, :test_tags) do
      {:ok, value} when is_boolean(value) -> Keyword.put(index_opts, :test_tags, value)
      _ -> index_opts
    end
  end

  defp run_commands?(opts) do
    case Keyword.fetch(opts, :run_commands) do
      {:ok, false} -> false
      _ -> true
    end
  end

  defp config_path(root, spec_dir) do
    if Path.type(spec_dir) == :absolute do
      Path.join(spec_dir, "config.yml")
    else
      Path.join([root, spec_dir, "config.yml"])
    end
  end

  # covers: specled.tasks.config_diagnostics_surfaced
  #
  # A broken `.spec/config.yml` override (e.g. a severity token specled cannot
  # parse) is dropped by Config.load and recorded as a diagnostic. Surface each
  # one as a stderr warning so the maintainer notices before the normal report;
  # these lines never change the task exit status.
  defp emit_config_diagnostics(%Config{diagnostics: diagnostics}) do
    Enum.each(diagnostics, fn %{message: message} ->
      Mix.shell().error("[CONFIG] #{message}")
    end)
  end

  defp verbose?(opts) do
    case Keyword.fetch(opts, :verbose) do
      {:ok, true} -> true
      {:ok, false} -> false
      :error -> System.get_env("SPECLED_SHOW_INFO") == "1"
    end
  end

  defp filter_for_stdout(findings, true), do: findings

  defp filter_for_stdout(findings, false) do
    Enum.reject(findings, fn finding ->
      (finding["severity"] || finding[:severity] || "warning")
      |> to_string()
      |> String.downcase() == "info"
    end)
  end

  defp print_debug_checks(checks) do
    Mix.shell().info("debug_checks=#{length(checks)}")

    Enum.each(checks, fn check ->
      status = String.upcase(check["status"] || "pass")
      subject_id = check["subject_id"] || "global"
      file = check["file"] || "-"
      code = check["code"] || "check"
      message = check["message"] || ""
      Mix.shell().info("[#{status}] #{subject_id} #{code} #{file} :: #{message}")
    end)
  end

  defp print_validation_findings(findings, verbose?) do
    findings
    |> filter_for_stdout(verbose?)
    |> Enum.each(fn finding ->
      severity = String.upcase(finding["severity"] || "warning")
      subject_id = finding["subject_id"] || "global"
      file = finding["file"] || "-"
      code = finding["code"] || "finding"
      message = finding["message"] || ""
      Mix.shell().info("[#{severity}] #{subject_id} #{code} #{file} :: #{message}")
    end)
  end

  defp print_branch_report(report, verbose?) do
    Mix.shell().info(
      "branch base=#{report["base"]} changed_files=#{report["summary"]["changed_files"]} findings=#{report["summary"]["findings"]}"
    )

    (report["findings"] || [])
    |> filter_for_stdout(verbose?)
    |> Enum.each(fn finding ->
      severity = String.upcase(finding["severity"] || "warning")
      file = finding["file"] || "-"
      Mix.shell().info("[#{severity}] #{finding["code"]} #{file} :: #{finding["message"]}")
    end)

    guidance = report["guidance"] || %{}
    impacted_subjects = guidance["impacted_subject_ids"] || []
    uncovered_policy_files = guidance["uncovered_policy_files"] || []

    Mix.shell().info("branch change_type=#{guidance["change_type"] || "non_contract_or_meta"}")
    Mix.shell().info("branch impacted_subjects=#{Enum.join(impacted_subjects, ", ")}")

    Mix.shell().info("branch uncovered_policy_files=#{Enum.join(uncovered_policy_files, ", ")}")

    Mix.shell().info("branch next=#{guidance["suggested_command"]}")
  end

  defp record_evidence(root, report, branch_report) do
    branch_findings = branch_report["findings"] || []
    report = Map.update(report, "findings", branch_findings, &(&1 ++ branch_findings))

    with {:ok, tree_hash} <- TreeHash.current(root),
         entry <- Entry.build(tree_hash, report),
         :ok <- Store.record(root, entry) do
      :ok
    else
      {:warning, warning} ->
        SpecLedEx.Evidence.Warnings.emit(warning)
        :ok

      {:error, reason} ->
        Mix.shell().error("evidence/local_write_failed: #{inspect(reason)}")
        :ok
    end
  end

  defp validate_min_strength!(nil), do: nil

  defp validate_min_strength!(value) do
    case VerificationStrength.normalize(value) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        Mix.raise("Invalid value for --min-strength: #{message}")
    end
  end
end
