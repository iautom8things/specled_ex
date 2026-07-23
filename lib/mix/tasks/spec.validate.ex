defmodule Mix.Tasks.Spec.Validate do
  use Mix.Task

  @requirements ["app.config"]

  alias SpecLedEx.Config
  alias SpecLedEx.Config.Prose
  alias SpecLedEx.Validator.RealizedByDedupCheck
  alias SpecLedEx.VerificationStrength

  @shortdoc "Validates authored specs"
  @moduledoc """
  Validates authored specs. Use `--output <path>` to write a derived state
  artifact.

  ## Options

    * `--run-commands` - execute `kind: command` verifications with `execute: true`
    * `--min-strength claimed|linked|executed` - require a minimum verification strength
    * `--command-timeout-ms <ms>` - override the command verification timeout
      for this run. Precedence is CLI flag, then `.spec/config.yml`
      `verification.command_timeout_ms`, then the verifier's 120 second default.
    * `--strict` - fail on warnings as well as errors
    * `--test-tags` / `--no-test-tags` - enable or disable test-tag scanning
      for this invocation, overriding `.spec/config.yml`
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          root: :string,
          output: :string,
          strict: :boolean,
          debug: :boolean,
          run_commands: :boolean,
          spec_dir: :string,
          min_strength: :string,
          command_timeout_ms: :integer,
          test_tags: :boolean
        ],
        aliases: [r: :root, o: :output, s: :strict, d: :debug]
      )

    validate_args!(rest, invalid)

    min_strength = validate_min_strength!(opts[:min_strength])
    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    config = Config.load(root, path: config_path(root, spec_dir))
    emit_config_diagnostics(config)
    command_timeout_ms = opts[:command_timeout_ms] || config.verification.command_timeout_ms
    verification_severities = config.verification.severities
    strict? = opts[:strict] || false
    debug? = opts[:debug] || false
    run_commands? = opts[:run_commands] || false

    index_opts =
      [spec_dir: spec_dir, authored_dir: authored_dir, config: config]
      |> maybe_put_test_tags(opts)

    index = SpecLedEx.index(root, index_opts)

    report =
      SpecLedEx.validate(index, root,
        strict: strict?,
        debug: debug?,
        run_commands: run_commands?,
        command_timeout_ms: command_timeout_ms,
        severities: verification_severities,
        min_strength: min_strength
      )
      |> with_validator_findings(index, root, strict?)

    if output = opts[:output] do
      path = SpecLedEx.write_state(index, report, root, output)
      Mix.shell().info("spec.validate wrote #{path}")
    end

    summary = report["summary"]

    Mix.shell().info(
      "status=#{report["status"]} errors=#{summary["errors"]} warnings=#{summary["warnings"]}"
    )

    if debug? do
      checks = report["checks"] || []
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

    if report["status"] == "fail" do
      Enum.each(report["findings"] || [], fn finding ->
        severity = String.upcase(finding["severity"] || "warning")
        subject_id = finding["subject_id"] || "global"
        file = finding["file"] || "-"
        code = finding["code"] || "finding"
        message = finding["message"] || ""
        Mix.shell().info("[#{severity}] #{subject_id} #{code} #{file} :: #{message}")
      end)

      Mix.raise("Spec validate failed: #{length(report["findings"] || [])} finding(s)")
    end
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    Mix.raise("Invalid arguments for spec.validate: #{details}")
  end

  defp maybe_put_test_tags(index_opts, task_opts) do
    case Keyword.fetch(task_opts, :test_tags) do
      {:ok, value} when is_boolean(value) -> Keyword.put(index_opts, :test_tags, value)
      _ -> index_opts
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

  defp validate_min_strength!(nil), do: nil

  defp validate_min_strength!(value) do
    case VerificationStrength.normalize(value) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        Mix.raise("Invalid value for --min-strength: #{message}")
    end
  end

  # Runs validator-time finding sources (prose-rot, realized_by dedup) and
  # merges any findings into the report. The dedup check has its severity
  # hardcoded to `:warning` per the requirement; the prose check resolves
  # severity via config. Both flow through the same merge so the report
  # status, error/warning counts, and finding sort order stay consistent.
  defp with_validator_findings(report, index, root, strict?) do
    config = Config.load(root)
    severities = config.branch_guard.severities

    new_findings =
      Prose.findings(index, config.prose, severities) ++
        RealizedByDedupCheck.findings(index)

    case new_findings do
      [] ->
        report

      _ ->
        merged = (report["findings"] || []) ++ new_findings
        sorted = Enum.sort_by(merged, &sort_key/1)

        errors = Enum.count(sorted, &(&1["severity"] == "error"))
        warnings = Enum.count(sorted, &(&1["severity"] == "warning"))
        fail? = errors > 0 or (strict? and warnings > 0)
        summary = Map.get(report, "summary", %{})

        summary =
          summary
          |> Map.put("errors", errors)
          |> Map.put("warnings", warnings)
          |> Map.put("findings", length(sorted))

        report
        |> Map.put("findings", sorted)
        |> Map.put("summary", summary)
        |> Map.put("status", if(fail?, do: "fail", else: "pass"))
    end
  end

  defp sort_key(finding) do
    {
      finding["file"] || "",
      finding["subject_id"] || "",
      finding["code"] || "",
      finding["message"] || ""
    }
  end
end
