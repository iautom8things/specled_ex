defmodule SpecLedEx.Verifier do
  @moduledoc false

  alias SpecLedEx.Schema.Verification, as: VerificationSchema
  alias SpecLedEx.TaggedTests
  alias SpecLedEx.TaggedTests.Attribution
  alias SpecLedEx.VerificationStrength

  @command_kind "command"
  @tagged_tests_kind "tagged_tests"
  @file_kinds ~w(file source_file test_file guide_file readme_file workflow_file test doc workflow contract)
  @known_verification_kinds VerificationSchema.kinds()
  @id_pattern ~r/^[a-z0-9][a-z0-9._-]*$/
  @default_command_timeout_ms 120_000
  @tagged_tests_command "mix test"

  def verify(index, root, opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)
    debug? = Keyword.get(opts, :debug, false)
    run_commands? = Keyword.get(opts, :run_commands, false)
    command_timeout_ms = Keyword.get(opts, :command_timeout_ms) || @default_command_timeout_ms
    severity_overrides = Keyword.get(opts, :severities, %{})
    cli_minimum_strength = normalize_minimum_strength!(Keyword.get(opts, :min_strength))
    subjects = index["subjects"] || []
    decisions = index["decisions"] || []
    tag_scan_enabled? = Map.has_key?(index, "test_tags")
    tag_map = tag_map_from_index(index)
    subject_ids = build_subject_ids(subjects)
    decision_ids = build_decision_ids(decisions)

    command_results =
      build_command_results(subjects, tag_map, root, run_commands?, command_timeout_ms)

    global_claim_ids = build_global_claim_ids(subjects)

    verification_claims =
      build_verification_claims(
        subjects,
        root,
        command_results,
        global_claim_ids,
        tag_map,
        cli_minimum_strength
      )

    findings =
      subjects
      |> Enum.flat_map(
        &verify_subject(
          &1,
          root,
          command_results,
          global_claim_ids,
          decision_ids,
          tag_map,
          tag_scan_enabled?
        )
      )
      |> then(fn subject_findings ->
        decision_findings =
          Enum.flat_map(decisions, fn decision ->
            verify_decision(decision, subject_ids, decision_ids, global_claim_ids)
          end)

        subject_findings ++ decision_findings
      end)
      |> then(&(&1 ++ duplicate_subject_id_findings(subjects)))
      |> then(&(&1 ++ duplicate_requirement_id_findings(subjects)))
      |> then(&(&1 ++ duplicate_scenario_id_findings(subjects)))
      |> then(&(&1 ++ duplicate_exception_id_findings(subjects)))
      |> then(&(&1 ++ duplicate_decision_id_findings(decisions)))
      |> then(&(&1 ++ invalid_id_format_findings(subjects, decisions)))
      |> then(&(&1 ++ verification_strength_findings(verification_claims)))
      |> then(&(&1 ++ SpecLedEx.TagFindings.findings(index)))
      |> apply_severity_overrides(severity_overrides)
      |> sort_findings()

    checks =
      if debug? do
        build_debug_checks(
          subjects,
          decisions,
          root,
          run_commands?,
          command_results,
          global_claim_ids,
          subject_ids,
          decision_ids,
          tag_map
        )
        |> sort_checks()
      else
        []
      end

    errors = Enum.count(findings, &(&1["severity"] == "error"))
    warnings = Enum.count(findings, &(&1["severity"] == "warning"))
    fail? = errors > 0 or (strict? and warnings > 0)

    report = %{
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "strict" => strict?,
      "run_commands" => run_commands?,
      "status" => if(fail?, do: "fail", else: "pass"),
      "summary" => %{
        "subjects" => length(subjects),
        "decisions" => length(decisions),
        "errors" => errors,
        "warnings" => warnings,
        "findings" => length(findings)
      },
      "verification" => verification_report(verification_claims, cli_minimum_strength),
      "findings" => findings
    }

    if debug? do
      Map.put(report, "checks", checks)
    else
      report
    end
  end

  defp verify_subject(
         subject,
         root,
         command_results,
         global_claim_ids,
         decision_ids,
         tag_map,
         tag_scan_enabled?
       ) do
    file = string_field(subject, "file")
    meta = subject_meta(subject)
    subject_id = id_of(meta, "id") || file
    reqs = map_items(field(subject, "requirements"))
    scenarios = map_items(field(subject, "scenarios"))
    verifications = verification_entries(subject, subject_id, file, command_results)
    exceptions = map_items(field(subject, "exceptions"))
    parse_errors = list_field(subject, "parse_errors")
    requirement_ids = reqs |> Enum.map(&id_of(&1, "id")) |> Enum.reject(&is_nil/1)
    scenario_ids = scenarios |> Enum.map(&id_of(&1, "id")) |> Enum.reject(&is_nil/1)
    local_claim_ids = MapSet.new(requirement_ids ++ scenario_ids)
    surface = list_field(meta, "surface")

    []
    |> add_meta_findings(meta, subject_id, file)
    |> add_parse_error_findings(parse_errors, subject_id, file)
    |> add_decision_reference_findings(meta, decision_ids, subject_id, file)
    |> add_missing_requirement_id_findings(reqs, subject_id, file)
    |> add_missing_scenario_id_findings(scenarios, subject_id, file)
    |> add_scenario_cover_findings(scenarios, MapSet.new(requirement_ids), subject_id, file)
    |> add_scenario_structure_findings(scenarios, subject_id, file)
    |> add_verification_findings(
      verifications,
      local_claim_ids,
      global_claim_ids,
      root,
      subject_id,
      file,
      tag_map,
      tag_scan_enabled?
    )
    |> add_requirement_coverage_findings(
      requirement_ids,
      verifications,
      exceptions,
      subject_id,
      file
    )
    |> add_surface_findings(surface, root, subject_id, file)
  end

  defp add_meta_findings(findings, meta, subject_id, file) do
    required = ["id", "kind", "status"]

    Enum.reduce(required, findings, fn key, acc ->
      if present_string?(meta, key) do
        acc
      else
        [
          finding(
            "error",
            "missing_meta_field",
            "Missing required spec-meta field: #{key}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_parse_error_findings(findings, parse_errors, subject_id, file) do
    Enum.reduce(parse_errors, findings, fn message, acc ->
      [finding("error", "parse_error", message, subject_id, file) | acc]
    end)
  end

  defp add_decision_reference_findings(findings, meta, decision_ids, subject_id, file) do
    meta
    |> list_field("decisions")
    |> Enum.reduce(findings, fn decision_id, acc ->
      if MapSet.member?(decision_ids, decision_id) do
        acc
      else
        [
          finding(
            "warning",
            "subject_unknown_decision_reference",
            "Subject references unknown decision id: #{decision_id}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_missing_requirement_id_findings(findings, requirements, subject_id, file) do
    Enum.reduce(requirements, findings, fn req, acc ->
      if present_string?(req, "id") do
        acc
      else
        [
          finding(
            "error",
            "missing_requirement_id",
            "Requirement entry is missing id",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_missing_scenario_id_findings(findings, scenarios, subject_id, file) do
    Enum.reduce(scenarios, findings, fn scenario, acc ->
      if present_string?(scenario, "id") do
        acc
      else
        [
          finding(
            "error",
            "missing_scenario_id",
            "Scenario entry is missing id",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_scenario_cover_findings(findings, scenarios, requirement_ids, subject_id, file) do
    Enum.reduce(scenarios, findings, fn scenario, acc ->
      covers = list_field(scenario, "covers")
      scenario_id = id_of(scenario, "id") || "<unknown>"

      Enum.reduce(covers, acc, fn cover_id, cover_acc ->
        if MapSet.member?(requirement_ids, cover_id) do
          cover_acc
        else
          [
            finding(
              "warning",
              "scenario_unknown_cover",
              "Scenario #{scenario_id} references unknown requirement id: #{cover_id}",
              subject_id,
              file
            )
            | cover_acc
          ]
        end
      end)
    end)
  end

  defp add_scenario_structure_findings(findings, scenarios, subject_id, file) do
    Enum.reduce(scenarios, findings, fn scenario, acc ->
      scenario_id = id_of(scenario, "id") || "<unknown>"

      Enum.reduce(["given", "when", "then"], acc, fn key, inner_acc ->
        case list_field(scenario, key) do
          list when is_list(list) and list != [] ->
            inner_acc

          _ ->
            [
              finding(
                "warning",
                "scenario_missing_#{key}",
                "Scenario #{scenario_id} is missing or has empty #{key}",
                subject_id,
                file
              )
              | inner_acc
            ]
        end
      end)
    end)
  end

  defp add_verification_findings(
         findings,
         verifications,
         local_claim_ids,
         global_claim_ids,
         root,
         subject_id,
         file,
         tag_map,
         tag_scan_enabled?
       ) do
    Enum.reduce(verifications, findings, fn entry, acc ->
      verification = entry.item

      acc
      |> add_verification_kind_findings(verification, subject_id, file)
      |> add_verification_target_findings(verification, root, subject_id, file)
      |> add_verification_cover_findings(
        verification,
        local_claim_ids,
        global_claim_ids,
        subject_id,
        file
      )
      |> add_verification_target_content_findings(verification, root, subject_id, file)
      |> add_verification_command_runtime_findings(
        verification,
        entry.command_result,
        subject_id,
        file
      )
      |> add_tagged_tests_cover_findings(
        verification,
        tag_map,
        tag_scan_enabled?,
        subject_id,
        file
      )
    end)
  end

  defp add_verification_kind_findings(findings, verification, subject_id, file) do
    kind = string_field(verification, "kind")

    if known_verification_kind?(kind) do
      findings
    else
      [
        finding(
          "error",
          "verification_unknown_kind",
          "Unknown verification kind: #{display_kind(kind)}",
          subject_id,
          file
        )
        | findings
      ]
    end
  end

  defp add_verification_command_runtime_findings(
         findings,
         verification,
         command_result,
         subject_id,
         file
       ) do
    kind = string_field(verification, "kind")
    target = string_field(verification, "target")
    execute? = bool_field(verification, "execute")

    cond do
      kind == @command_kind and execute? and target != "" and command_result ->
        append_command_runtime_finding(findings, command_result, target, subject_id, file)

      kind == @tagged_tests_kind and execute? and command_result ->
        case Map.get(command_result, :attribution) do
          nil ->
            label = "tagged_tests: #{Map.get(command_result, :command) || @tagged_tests_command}"
            append_command_runtime_finding(findings, command_result, label, subject_id, file)

          attribution ->
            append_attributed_tagged_tests_findings(
              findings,
              command_result,
              attribution,
              subject_id,
              file
            )
        end

      true ->
        findings
    end
  end

  # Evidence-based findings for a merged tagged_tests run whose artifact was
  # readable. Only covers with recorded failures redden their subjects; passing
  # covers are silent (they reach `executed` via cover_executed?/2); a timeout
  # names the in-flight hang suspects and counts the never-started remainder;
  # runtime-excluded covers get the `tagged_tests_cover_not_executed` warning.
  defp append_attributed_tagged_tests_findings(
         findings,
         command_result,
         attribution,
         subject_id,
         file
       ) do
    findings
    |> append_attributed_failure_finding(command_result, attribution, subject_id, file)
    |> append_attributed_timeout_finding(command_result, attribution, subject_id, file)
    |> append_not_executed_findings(attribution, subject_id, file)
  end

  defp append_attributed_failure_finding(findings, command_result, attribution, subject_id, file) do
    case attributed_failing_tests(attribution) do
      [] ->
        findings

      tests ->
        label = Map.get(command_result, :command) || @tagged_tests_command

        [
          finding(
            "error",
            "verification_command_failed",
            "Verification command failed: tagged_tests: #{label}\nexit_code=#{inspect(Map.get(command_result, :exit_code))}\nfailing tests: #{Enum.join(tests, ", ")}",
            subject_id,
            file
          )
          | findings
        ]
    end
  end

  defp append_attributed_timeout_finding(findings, command_result, attribution, subject_id, file) do
    if command_timed_out?(command_result) do
      label = Map.get(command_result, :command) || @tagged_tests_command

      [
        finding(
          "error",
          "verification_command_timeout",
          "Verification command timed out: tagged_tests: #{label}\n#{attributed_timeout_details(command_result, attribution)}",
          subject_id,
          file
        )
        | findings
      ]
    else
      findings
    end
  end

  defp append_not_executed_findings(findings, attribution, subject_id, file) do
    attribution
    |> Enum.filter(fn {_cover_id, outcome} -> outcome == :not_executed end)
    |> Enum.reduce(findings, fn {cover_id, _outcome}, acc ->
      [
        finding(
          "warning",
          "tagged_tests_cover_not_executed",
          "tagged_tests cover #{cover_id} has @tag spec entries but no test executed in the merged run (skipped, excluded, or filtered out)",
          subject_id,
          file
        )
        | acc
      ]
    end)
  end

  defp attributed_failing_tests(attribution) do
    attribution
    |> Enum.flat_map(fn
      {_cover_id, {:failed, tests}} -> tests
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp attributed_timeout_details(command_result, attribution) do
    hang_suspects = attributed_hang_suspects(attribution)
    remainder = attributed_not_started_count(attribution)

    evidence =
      cond do
        Map.get(command_result, :attribution_empty, false) and hang_suspects == [] ->
          "timed out before any test started — likely compile cost"

        hang_suspects != [] ->
          "timed out while running #{Enum.join(hang_suspects, ", ")}#{remainder_suffix(remainder)}"

        true ->
          "no test was observed still running at timeout#{remainder_suffix(remainder)}"
      end

    "#{command_timeout_core(command_result)}\n#{evidence}#{resume_timeout_suffix(command_result)}"
  end

  # When a resume pass re-ran the never-started remainder alone with a fresh full
  # budget and still timed out, the budget is no longer the likely explanation:
  # a test that hangs on an isolated re-run is the suspect. Name the resume run's
  # own in-flight tests when it recorded any.
  defp resume_timeout_suffix(command_result) do
    if Map.get(command_result, :resume_timed_out, false) do
      case Map.get(command_result, :resume_in_flight, []) do
        [] ->
          "\nthe resume pass re-ran the timeout remainder alone with a fresh full budget and still timed out — the remaining tests, not the budget, are the likely problem"

        suspects ->
          "\nthe resume pass re-ran the timeout remainder alone with a fresh full budget and still timed out on #{Enum.join(suspects, ", ")} — this test, not the budget, is the likely problem"
      end
    else
      ""
    end
  end

  defp attributed_hang_suspects(attribution) do
    attribution
    |> Enum.flat_map(fn
      {_cover_id, {:in_flight, tests}} -> tests
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp attributed_not_started_count(attribution) do
    Enum.count(attribution, fn {_cover_id, outcome} -> outcome == :not_started end)
  end

  defp remainder_suffix(0), do: ""

  defp remainder_suffix(count),
    do: "; #{count} cover id(s) never started (timeout remainder)"

  defp append_attributed_tagged_tests_checks(checks, command_result, subject_id, file) do
    Enum.reduce(Map.get(command_result, :attribution), checks, fn {cover_id, outcome}, acc ->
      {status, code, message} = attributed_cover_check(cover_id, outcome)
      [check(status, code, message, subject_id, file) | acc]
    end)
  end

  defp attributed_cover_check(cover_id, :passed),
    do: {"pass", "verification_command_passed", "tagged_tests cover executed: #{cover_id}"}

  defp attributed_cover_check(cover_id, {:failed, tests}),
    do:
      {"error", "verification_command_failed",
       "tagged_tests cover failed: #{cover_id} (#{Enum.join(tests, ", ")})"}

  defp attributed_cover_check(cover_id, {:in_flight, tests}),
    do:
      {"error", "verification_command_timeout",
       "tagged_tests cover in flight at timeout: #{cover_id} (#{Enum.join(tests, ", ")})"}

  defp attributed_cover_check(cover_id, :not_started),
    do:
      {"error", "verification_command_timeout",
       "tagged_tests cover never started (timeout remainder): #{cover_id}"}

  defp attributed_cover_check(cover_id, :not_executed),
    do:
      {"warning", "tagged_tests_cover_not_executed",
       "tagged_tests cover not executed: #{cover_id}"}

  defp append_command_runtime_finding(findings, command_result, label, subject_id, file) do
    %{output: output, exit_code: exit_code} = command_result

    cond do
      command_timed_out?(command_result) ->
        details = command_timeout_details(command_result)

        [
          finding(
            "error",
            "verification_command_timeout",
            "Verification command timed out: #{label}\n#{details}",
            subject_id,
            file
          )
          | findings
        ]

      exit_code == 0 ->
        findings

      true ->
        details = command_failure_details(output, exit_code, command_result)

        [
          finding(
            "error",
            "verification_command_failed",
            "Verification command failed: #{label}\n#{details}",
            subject_id,
            file
          )
          | findings
        ]
    end
  end

  defp command_failure_details(output, exit_code, command_result \\ %{}) do
    trimmed = String.trim(output || "")
    header = "exit_code=#{exit_code}"

    details =
      cond do
        trimmed == "" ->
          header

        String.length(trimmed) <= 2_000 ->
          "#{header}\n#{trimmed}"

        true ->
          head = String.slice(trimmed, 0, 1_000)
          tail_start = max(String.length(trimmed) - 1_000, 0)
          tail = String.slice(trimmed, tail_start, 1_000)

          "#{header}\n#{head}\n...[output truncated]...\n#{tail}"
      end

    append_shared_tagged_tests_context(details, command_result)
  end

  defp command_timeout_details(command_result) do
    command_result
    |> command_timeout_core()
    |> append_shared_tagged_tests_context(command_result)
  end

  defp command_timeout_core(command_result) do
    timeout_ms = Map.get(command_result, :timeout_ms, @default_command_timeout_ms)
    doubled_timeout_ms = timeout_ms * 2

    "command exceeded #{timeout_ms}ms (verification.command_timeout_ms in .spec/config.yml, default #{@default_command_timeout_ms}); tests were not observed to fail. Re-run with --command-timeout-ms #{doubled_timeout_ms} to confirm this is a budget problem."
  end

  defp append_shared_tagged_tests_context(message, command_result) do
    case Map.get(command_result, :tagged_tests_shared_count) do
      count when is_integer(count) and count > 0 ->
        "#{message}\naggregated tagged_tests run (1 command shared by #{count} subjects) - this finding reflects the shared run, not a subject-specific failure."

      _ ->
        message
    end
  end

  defp command_timed_out?(command_result) do
    Map.get(command_result, :timed_out) == true
  end

  defp add_tagged_tests_cover_findings(
         findings,
         verification,
         tag_map,
         tag_scan_enabled?,
         subject_id,
         file
       ) do
    if tag_scan_enabled? and string_field(verification, "kind") == @tagged_tests_kind do
      verification
      |> valid_cover_ids()
      |> Enum.reject(&Map.has_key?(tag_map, &1))
      |> Enum.reduce(findings, fn cover_id, acc ->
        [
          finding(
            "warning",
            "tagged_tests_cover_missing_tag",
            "tagged_tests verification covers #{cover_id} but no test carries @tag spec: #{cover_id}",
            subject_id,
            file
          )
          | acc
        ]
      end)
    else
      findings
    end
  end

  defp add_verification_target_findings(findings, verification, root, subject_id, file) do
    kind = string_field(verification, "kind")
    target = string_field(verification, "target")

    cond do
      kind in @file_kinds and target == "" ->
        [
          finding(
            "error",
            "verification_missing_target",
            "Verification item is missing target path",
            subject_id,
            file
          )
          | findings
        ]

      kind in @file_kinds and not File.exists?(Path.expand(target, root)) ->
        [
          finding(
            "warning",
            "verification_target_missing",
            "Verification target file does not exist: #{target}",
            subject_id,
            file
          )
          | findings
        ]

      kind == "command" and target == "" ->
        [
          finding(
            "error",
            "verification_missing_command",
            "Verification command target is empty",
            subject_id,
            file
          )
          | findings
        ]

      true ->
        findings
    end
  end

  defp add_verification_cover_findings(
         findings,
         verification,
         local_claim_ids,
         global_claim_ids,
         subject_id,
         file
       ) do
    covers = list_field(verification, "covers")

    Enum.reduce(covers, findings, fn cover_id, acc ->
      cond do
        MapSet.member?(local_claim_ids, cover_id) ->
          acc

        MapSet.member?(global_claim_ids, cover_id) ->
          acc

        true ->
          [
            finding(
              "warning",
              "verification_unknown_cover",
              "Verification references unknown claim id: #{cover_id}",
              subject_id,
              file
            )
            | acc
          ]
      end
    end)
  end

  defp add_verification_target_content_findings(findings, verification, root, subject_id, file) do
    kind = string_field(verification, "kind")
    target = string_field(verification, "target")
    covers = valid_cover_ids(verification)

    if kind in @file_kinds and target != "" and covers != [] do
      full_path = Path.expand(target, root)

      case File.read(full_path) do
        {:ok, content} ->
          Enum.reduce(covers, findings, fn cover_id, acc ->
            if String.contains?(content, cover_id) do
              acc
            else
              [
                finding(
                  "warning",
                  "verification_target_missing_reference",
                  "Verification target #{target} does not reference covered requirement: #{cover_id}",
                  subject_id,
                  file
                )
                | acc
              ]
            end
          end)

        {:error, _} ->
          findings
      end
    else
      findings
    end
  end

  defp add_surface_findings(findings, surface, root, subject_id, file) do
    Enum.reduce(surface, findings, fn surface_entry, acc ->
      if path_like?(surface_entry) and not File.exists?(Path.expand(surface_entry, root)) do
        [
          finding(
            "warning",
            "surface_target_missing",
            "Surface entry does not exist: #{surface_entry}",
            subject_id,
            file
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp path_like?(entry) do
    not String.contains?(entry, " ") and
      not glob_pattern?(entry) and
      (String.contains?(entry, "/") or String.contains?(entry, "."))
  end

  defp glob_pattern?(entry) do
    String.contains?(entry, "*") or String.contains?(entry, "?") or String.contains?(entry, "[")
  end

  defp add_requirement_coverage_findings(
         findings,
         requirement_ids,
         verifications,
         exceptions,
         subject_id,
         file
       ) do
    covered_ids =
      coverage_items(verifications, exceptions)
      |> Enum.flat_map(&list_field(&1, "covers"))
      |> MapSet.new()

    Enum.reduce(requirement_ids, findings, fn req_id, acc ->
      if MapSet.member?(covered_ids, req_id) do
        acc
      else
        [
          finding(
            "warning",
            "requirement_without_verification",
            "Requirement is not referenced by any verification item: #{req_id}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp tag_map_from_index(index) when is_map(index) do
    case Map.get(index, "test_tags") do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp tag_map_from_index(_), do: %{}

  defp build_global_claim_ids(subjects) do
    subjects
    |> Enum.flat_map(fn subject ->
      requirement_ids =
        subject
        |> field("requirements")
        |> map_items()
        |> Enum.map(&id_of(&1, "id"))

      scenario_ids =
        subject
        |> field("scenarios")
        |> map_items()
        |> Enum.map(&id_of(&1, "id"))

      requirement_ids ++ scenario_ids
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp build_debug_checks(
         subjects,
         decisions,
         root,
         run_commands?,
         command_results,
         global_claim_ids,
         subject_ids,
         decision_ids,
         tag_map
       ) do
    subject_checks =
      subjects
      |> Enum.flat_map(
        &build_subject_debug_checks(
          &1,
          root,
          run_commands?,
          command_results,
          global_claim_ids,
          decision_ids,
          tag_map
        )
      )

    decision_checks =
      decisions
      |> Enum.flat_map(
        &build_decision_debug_checks(&1, subject_ids, decision_ids, global_claim_ids)
      )

    global_checks =
      []
      |> add_duplicate_subject_debug_checks(subjects)
      |> add_duplicate_requirement_debug_checks(subjects)
      |> add_duplicate_decision_debug_checks(decisions)

    subject_checks ++ decision_checks ++ global_checks
  end

  defp build_subject_debug_checks(
         subject,
         root,
         run_commands?,
         command_results,
         global_claim_ids,
         decision_ids,
         tag_map
       ) do
    file = string_field(subject, "file")
    meta = subject_meta(subject)
    subject_id = id_of(meta, "id") || file
    requirements = map_items(field(subject, "requirements"))
    scenarios = map_items(field(subject, "scenarios"))
    verifications = verification_entries(subject, subject_id, file, command_results)
    exceptions = map_items(field(subject, "exceptions"))
    parse_errors = list_field(subject, "parse_errors")
    requirement_ids = requirements |> Enum.map(&id_of(&1, "id")) |> Enum.reject(&is_nil/1)
    scenario_ids = scenarios |> Enum.map(&id_of(&1, "id")) |> Enum.reject(&is_nil/1)
    local_claim_ids = MapSet.new(requirement_ids ++ scenario_ids)
    surface = list_field(meta, "surface")

    []
    |> add_meta_debug_checks(meta, subject_id, file)
    |> add_parse_debug_checks(parse_errors, subject_id, file)
    |> add_decision_reference_debug_checks(meta, decision_ids, subject_id, file)
    |> add_requirement_id_debug_checks(requirements, subject_id, file)
    |> add_scenario_id_debug_checks(scenarios, subject_id, file)
    |> add_scenario_cover_debug_checks(scenarios, MapSet.new(requirement_ids), subject_id, file)
    |> add_verification_debug_checks(
      verifications,
      local_claim_ids,
      global_claim_ids,
      root,
      subject_id,
      file,
      run_commands?,
      tag_map
    )
    |> add_requirement_coverage_debug_checks(
      requirement_ids,
      verifications,
      exceptions,
      subject_id,
      file
    )
    |> add_surface_debug_checks(surface, root, subject_id, file)
  end

  defp add_meta_debug_checks(checks, meta, subject_id, file) do
    required = ["id", "kind", "status"]

    Enum.reduce(required, checks, fn key, acc ->
      if present_string?(meta, key) do
        [
          check("pass", "meta_field_present", "spec-meta field present: #{key}", subject_id, file)
          | acc
        ]
      else
        [
          check(
            "error",
            "meta_field_missing",
            "spec-meta field missing: #{key}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_parse_debug_checks(checks, parse_errors, subject_id, file) do
    if parse_errors == [] do
      [
        check(
          "pass",
          "parse_blocks",
          "Structured spec blocks parsed successfully",
          subject_id,
          file
        )
        | checks
      ]
    else
      Enum.reduce(parse_errors, checks, fn message, acc ->
        [check("error", "parse_blocks", message, subject_id, file) | acc]
      end)
    end
  end

  defp add_decision_reference_debug_checks(checks, meta, decision_ids, subject_id, file) do
    meta
    |> list_field("decisions")
    |> Enum.reduce(checks, fn decision_id, acc ->
      if MapSet.member?(decision_ids, decision_id) do
        [
          check(
            "pass",
            "decision_reference_valid",
            "Subject references known decision: #{decision_id}",
            subject_id,
            file
          )
          | acc
        ]
      else
        [
          check(
            "warning",
            "decision_reference_unknown",
            "Subject references unknown decision: #{decision_id}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_requirement_id_debug_checks(checks, requirements, subject_id, file) do
    Enum.reduce(requirements, checks, fn requirement, acc ->
      case string_field(requirement, "id") do
        id when is_binary(id) and id != "" ->
          [
            check(
              "pass",
              "requirement_id_present",
              "Requirement id present: #{id}",
              subject_id,
              file
            )
            | acc
          ]

        _ ->
          [
            check(
              "error",
              "requirement_id_missing",
              "Requirement entry missing id",
              subject_id,
              file
            )
            | acc
          ]
      end
    end)
  end

  defp add_scenario_id_debug_checks(checks, scenarios, subject_id, file) do
    Enum.reduce(scenarios, checks, fn scenario, acc ->
      case string_field(scenario, "id") do
        id when is_binary(id) and id != "" ->
          [
            check("pass", "scenario_id_present", "Scenario id present: #{id}", subject_id, file)
            | acc
          ]

        _ ->
          [
            check("error", "scenario_id_missing", "Scenario entry missing id", subject_id, file)
            | acc
          ]
      end
    end)
  end

  defp add_scenario_cover_debug_checks(checks, scenarios, requirement_ids, subject_id, file) do
    Enum.reduce(scenarios, checks, fn scenario, acc ->
      covers = list_field(scenario, "covers")
      scenario_id = id_of(scenario, "id") || "<unknown>"

      Enum.reduce(covers, acc, fn cover_id, cover_acc ->
        if MapSet.member?(requirement_ids, cover_id) do
          [
            check(
              "pass",
              "scenario_cover_valid",
              "Scenario #{scenario_id} covers known requirement: #{cover_id}",
              subject_id,
              file
            )
            | cover_acc
          ]
        else
          [
            check(
              "warning",
              "scenario_cover_unknown",
              "Scenario #{scenario_id} covers unknown requirement: #{cover_id}",
              subject_id,
              file
            )
            | cover_acc
          ]
        end
      end)
    end)
  end

  defp add_verification_debug_checks(
         checks,
         verifications,
         local_claim_ids,
         global_claim_ids,
         root,
         subject_id,
         file,
         run_commands?,
         _tag_map
       ) do
    Enum.reduce(verifications, checks, fn entry, acc ->
      verification = entry.item
      kind = string_field(verification, "kind")
      target = string_field(verification, "target")
      covers = list_field(verification, "covers")
      execute? = bool_field(verification, "execute")
      command_result = entry.command_result

      acc =
        cond do
          not known_verification_kind?(kind) ->
            [
              check(
                "error",
                "verification_kind_invalid",
                "Unknown verification kind: #{display_kind(kind)}",
                subject_id,
                file
              )
              | acc
            ]

          kind in @file_kinds and target == "" ->
            [
              check(
                "error",
                "verification_target_missing",
                "Verification target path missing",
                subject_id,
                file
              )
              | acc
            ]

          kind in @file_kinds and File.exists?(Path.expand(target, root)) ->
            [
              check(
                "pass",
                "verification_target_exists",
                "Verification file exists: #{target}",
                subject_id,
                file
              )
              | acc
            ]

          kind in @file_kinds ->
            [
              check(
                "warning",
                "verification_target_missing_file",
                "Verification file not found: #{target}",
                subject_id,
                file
              )
              | acc
            ]

          kind == @command_kind and target == "" ->
            [
              check(
                "error",
                "verification_command_missing",
                "Verification command is empty",
                subject_id,
                file
              )
              | acc
            ]

          kind == @command_kind and run_commands? and execute? and command_result ->
            %{output: output, exit_code: exit_code} = command_result

            cond do
              command_timed_out?(command_result) ->
                details = command_timeout_details(command_result)

                [
                  check(
                    "error",
                    "verification_command_timeout",
                    "Verification command timed out: #{target}\n#{details}",
                    subject_id,
                    file
                  )
                  | acc
                ]

              exit_code == 0 ->
                [
                  check(
                    "pass",
                    "verification_command_passed",
                    "Verification command passed: #{target}",
                    subject_id,
                    file
                  )
                  | acc
                ]

              true ->
                details = command_failure_details(output, exit_code)

                [
                  check(
                    "error",
                    "verification_command_failed",
                    "Verification command failed: #{target}\n#{details}",
                    subject_id,
                    file
                  )
                  | acc
                ]
            end

          kind == @command_kind and run_commands? and not execute? ->
            [
              check(
                "pass",
                "verification_command_skipped",
                "Verification command not executed (set execute=true to run): #{target}",
                subject_id,
                file
              )
              | acc
            ]

          kind == @command_kind ->
            [
              check(
                "pass",
                "verification_command_present",
                "Verification command present: #{target}",
                subject_id,
                file
              )
              | acc
            ]

          kind == @tagged_tests_kind and run_commands? and execute? and command_result and
              Map.has_key?(command_result, :attribution) ->
            append_attributed_tagged_tests_checks(acc, command_result, subject_id, file)

          kind == @tagged_tests_kind and run_commands? and execute? and command_result ->
            %{output: output, exit_code: exit_code, command: cmd} = command_result
            label = cmd || @tagged_tests_command

            cond do
              command_timed_out?(command_result) ->
                details = command_timeout_details(command_result)

                [
                  check(
                    "error",
                    "verification_command_timeout",
                    "tagged_tests command timed out: #{label}\n#{details}",
                    subject_id,
                    file
                  )
                  | acc
                ]

              exit_code == 0 ->
                [
                  check(
                    "pass",
                    "verification_command_passed",
                    "tagged_tests command passed: #{label}",
                    subject_id,
                    file
                  )
                  | acc
                ]

              true ->
                details = command_failure_details(output, exit_code, command_result)

                [
                  check(
                    "error",
                    "verification_command_failed",
                    "tagged_tests command failed: #{label}\n#{details}",
                    subject_id,
                    file
                  )
                  | acc
                ]
            end

          kind == @tagged_tests_kind and run_commands? and not execute? ->
            [
              check(
                "pass",
                "verification_command_skipped",
                "tagged_tests verification not executed (set execute=true to run)",
                subject_id,
                file
              )
              | acc
            ]

          kind == @tagged_tests_kind ->
            [
              check(
                "pass",
                "verification_command_present",
                "tagged_tests verification present (covers: #{Enum.join(covers, ", ")})",
                subject_id,
                file
              )
              | acc
            ]

          true ->
            [
              check(
                "pass",
                "verification_kind_seen",
                "Verification kind seen: #{kind}",
                subject_id,
                file
              )
              | acc
            ]
        end

      Enum.reduce(covers, acc, fn cover_id, cover_acc ->
        cond do
          MapSet.member?(local_claim_ids, cover_id) ->
            [
              check(
                "pass",
                "verification_cover_valid",
                "Verification covers known claim: #{cover_id}",
                subject_id,
                file
              )
              | cover_acc
            ]

          MapSet.member?(global_claim_ids, cover_id) ->
            [
              check(
                "pass",
                "verification_cover_valid",
                "Verification covers known claim (cross-subject): #{cover_id}",
                subject_id,
                file
              )
              | cover_acc
            ]

          true ->
            [
              check(
                "warning",
                "verification_cover_unknown",
                "Verification covers unknown claim: #{cover_id}",
                subject_id,
                file
              )
              | cover_acc
            ]
        end
      end)
    end)
  end

  defp add_requirement_coverage_debug_checks(
         checks,
         requirement_ids,
         verifications,
         exceptions,
         subject_id,
         file
       ) do
    covered_ids =
      coverage_items(verifications, exceptions)
      |> Enum.flat_map(&list_field(&1, "covers"))
      |> MapSet.new()

    Enum.reduce(requirement_ids, checks, fn req_id, acc ->
      if MapSet.member?(covered_ids, req_id) do
        [
          check(
            "pass",
            "requirement_has_verification",
            "Requirement has verification: #{req_id}",
            subject_id,
            file
          )
          | acc
        ]
      else
        [
          check(
            "warning",
            "requirement_missing_verification",
            "Requirement missing verification coverage: #{req_id}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_surface_debug_checks(checks, surface, root, subject_id, file) do
    Enum.reduce(surface, checks, fn surface_entry, acc ->
      if path_like?(surface_entry) do
        if File.exists?(Path.expand(surface_entry, root)) do
          [
            check(
              "pass",
              "surface_target_exists",
              "Surface entry exists: #{surface_entry}",
              subject_id,
              file
            )
            | acc
          ]
        else
          [
            check(
              "warning",
              "surface_target_missing",
              "Surface entry does not exist: #{surface_entry}",
              subject_id,
              file
            )
            | acc
          ]
        end
      else
        [
          check(
            "pass",
            "surface_target_skipped",
            "Surface entry is not path-like, skipped: #{surface_entry}",
            subject_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_duplicate_subject_debug_checks(checks, subjects) do
    duplicates =
      subjects
      |> Enum.map(fn subject -> subject |> subject_meta() |> id_of("id") end)
      |> Enum.reject(&is_nil/1)
      |> duplicates()

    if duplicates == [] do
      [check("pass", "duplicate_subject_id", "No duplicate subject ids", nil, nil) | checks]
    else
      Enum.reduce(duplicates, checks, fn id, acc ->
        [check("error", "duplicate_subject_id", "Duplicate subject id: #{id}", id, nil) | acc]
      end)
    end
  end

  defp add_duplicate_requirement_debug_checks(checks, subjects) do
    duplicates =
      subjects
      |> Enum.flat_map(fn subject -> list_field(subject, "requirements") end)
      |> Enum.map(&id_of(&1, "id"))
      |> Enum.reject(&is_nil/1)
      |> duplicates()

    if duplicates == [] do
      [
        check("pass", "duplicate_requirement_id", "No duplicate requirement ids", nil, nil)
        | checks
      ]
    else
      Enum.reduce(duplicates, checks, fn id, acc ->
        [
          check("error", "duplicate_requirement_id", "Duplicate requirement id: #{id}", nil, nil)
          | acc
        ]
      end)
    end
  end

  defp build_decision_debug_checks(decision, subject_ids, decision_ids, claim_ids) do
    file = string_field(decision, "file")
    meta = decision_meta(decision)
    decision_id = id_of(meta, "id") || file

    []
    |> add_decision_meta_debug_checks(meta, decision_id, file)
    |> add_decision_parse_debug_checks(list_field(decision, "parse_errors"), decision_id, file)
    |> add_decision_section_debug_checks(list_field(decision, "sections"), decision_id, file)
    |> add_decision_affects_debug_checks(meta, subject_ids, claim_ids, decision_id, file)
    |> add_decision_supersession_debug_checks(meta, decision_ids, decision_id, file)
  end

  defp add_decision_meta_debug_checks(checks, meta, decision_id, file) do
    required = ["id", "status", "date", "affects"]

    checks =
      Enum.reduce(required, checks, fn key, acc ->
        present? =
          case key do
            "affects" -> list_field(meta, key) != []
            _ -> present_string?(meta, key)
          end

        if present? do
          [
            check(
              "pass",
              "decision_meta_field_present",
              "Decision field present: #{key}",
              decision_id,
              file
            )
            | acc
          ]
        else
          [
            check(
              "error",
              "decision_meta_field_missing",
              "Decision field missing: #{key}",
              decision_id,
              file
            )
            | acc
          ]
        end
      end)

    checks
    |> add_decision_status_debug_check(meta, decision_id, file)
    |> add_decision_date_debug_check(meta, decision_id, file)
  end

  defp add_decision_status_debug_check(checks, meta, decision_id, file) do
    status = string_field(meta, "status")

    if status in ~w(accepted superseded) do
      [
        check(
          "pass",
          "decision_status_valid",
          "Decision status valid: #{status}",
          decision_id,
          file
        )
        | checks
      ]
    else
      [
        check(
          "error",
          "decision_status_invalid",
          "Decision status invalid: #{display_kind(status)}",
          decision_id,
          file
        )
        | checks
      ]
    end
  end

  defp add_decision_date_debug_check(checks, meta, decision_id, file) do
    date = string_field(meta, "date")

    if valid_iso_date?(date) do
      [
        check("pass", "decision_date_valid", "Decision date valid: #{date}", decision_id, file)
        | checks
      ]
    else
      [
        check(
          "error",
          "decision_date_invalid",
          "Decision date is not ISO-8601: #{display_kind(date)}",
          decision_id,
          file
        )
        | checks
      ]
    end
  end

  defp add_decision_parse_debug_checks(checks, parse_errors, decision_id, file) do
    if parse_errors == [] do
      [
        check("pass", "decision_parse", "Decision parsed successfully", decision_id, file)
        | checks
      ]
    else
      Enum.reduce(parse_errors, checks, fn message, acc ->
        [check("error", "decision_parse", message, decision_id, file) | acc]
      end)
    end
  end

  defp add_decision_section_debug_checks(checks, sections, decision_id, file) do
    Enum.reduce(SpecLedEx.DecisionParser.required_sections(), checks, fn section, acc ->
      if section in sections do
        [
          check(
            "pass",
            "decision_section_present",
            "Decision section present: #{section}",
            decision_id,
            file
          )
          | acc
        ]
      else
        [
          check(
            "error",
            "decision_section_missing",
            "Decision section missing: #{section}",
            decision_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_decision_affects_debug_checks(checks, meta, subject_ids, claim_ids, decision_id, file) do
    Enum.reduce(list_field(meta, "affects"), checks, fn affect, acc ->
      if valid_decision_affect?(affect, subject_ids, claim_ids) do
        [
          check(
            "pass",
            "decision_affect_valid",
            "Decision affect valid: #{affect}",
            decision_id,
            file
          )
          | acc
        ]
      else
        [
          check(
            "error",
            "decision_affect_invalid",
            "Decision affect invalid: #{affect}",
            decision_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_decision_supersession_debug_checks(checks, meta, decision_ids, decision_id, file) do
    status = string_field(meta, "status")
    superseded_by = string_field(meta, "superseded_by")

    cond do
      status == "superseded" and superseded_by == "" ->
        [
          check(
            "error",
            "decision_superseded_by_missing",
            "Superseded decision missing superseded_by",
            decision_id,
            file
          )
          | checks
        ]

      superseded_by != "" and MapSet.member?(decision_ids, superseded_by) ->
        [
          check(
            "pass",
            "decision_superseded_by_valid",
            "Decision replacement exists: #{superseded_by}",
            decision_id,
            file
          )
          | checks
        ]

      superseded_by != "" ->
        [
          check(
            "error",
            "decision_superseded_by_unknown",
            "Decision replacement not found: #{superseded_by}",
            decision_id,
            file
          )
          | checks
        ]

      true ->
        checks
    end
  end

  defp add_duplicate_decision_debug_checks(checks, decisions) do
    duplicates =
      decisions
      |> Enum.map(fn decision -> decision |> decision_meta() |> id_of("id") end)
      |> Enum.reject(&is_nil/1)
      |> duplicates()

    if duplicates == [] do
      [check("pass", "duplicate_decision_id", "No duplicate decision ids", nil, nil) | checks]
    else
      Enum.reduce(duplicates, checks, fn id, acc ->
        [check("error", "duplicate_decision_id", "Duplicate decision id: #{id}", id, nil) | acc]
      end)
    end
  end

  defp verify_decision(decision, subject_ids, decision_ids, claim_ids) do
    file = string_field(decision, "file")
    meta = decision_meta(decision)
    decision_id = id_of(meta, "id") || file

    []
    |> add_decision_meta_findings(meta, decision_id, file)
    |> add_decision_parse_error_findings(list_field(decision, "parse_errors"), decision_id, file)
    |> add_decision_section_findings(list_field(decision, "sections"), decision_id, file)
    |> add_decision_affects_findings(meta, subject_ids, claim_ids, decision_id, file)
    |> add_decision_supersession_findings(meta, decision_ids, decision_id, file)
  end

  defp add_decision_meta_findings(findings, meta, decision_id, file) do
    required = ["id", "status", "date", "affects"]

    findings =
      Enum.reduce(required, findings, fn key, acc ->
        present? =
          case key do
            "affects" -> list_field(meta, key) != []
            _ -> present_string?(meta, key)
          end

        if present? do
          acc
        else
          [
            finding(
              "error",
              "decision_missing_meta_field",
              "Decision frontmatter missing required field: #{key}",
              decision_id,
              file
            )
            | acc
          ]
        end
      end)

    findings
    |> add_decision_status_findings(meta, decision_id, file)
    |> add_decision_date_findings(meta, decision_id, file)
  end

  defp add_decision_status_findings(findings, meta, decision_id, file) do
    status = string_field(meta, "status")

    if status == "" or status in ~w(accepted superseded) do
      findings
    else
      [
        finding(
          "error",
          "decision_invalid_status",
          "Decision status must be accepted or superseded: #{status}",
          decision_id,
          file
        )
        | findings
      ]
    end
  end

  defp add_decision_date_findings(findings, meta, decision_id, file) do
    date = string_field(meta, "date")

    if date == "" or valid_iso_date?(date) do
      findings
    else
      [
        finding(
          "error",
          "decision_invalid_date",
          "Decision date must be ISO-8601 (YYYY-MM-DD): #{date}",
          decision_id,
          file
        )
        | findings
      ]
    end
  end

  defp add_decision_parse_error_findings(findings, parse_errors, decision_id, file) do
    Enum.reduce(parse_errors, findings, fn message, acc ->
      [finding("error", "decision_parse_error", message, decision_id, file) | acc]
    end)
  end

  defp add_decision_section_findings(findings, sections, decision_id, file) do
    Enum.reduce(SpecLedEx.DecisionParser.required_sections(), findings, fn section, acc ->
      if section in sections do
        acc
      else
        [
          finding(
            "error",
            "decision_missing_section",
            "Decision is missing required section: #{section}",
            decision_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_decision_affects_findings(findings, meta, subject_ids, claim_ids, decision_id, file) do
    Enum.reduce(list_field(meta, "affects"), findings, fn affect, acc ->
      if valid_decision_affect?(affect, subject_ids, claim_ids) do
        acc
      else
        [
          finding(
            "error",
            "decision_unknown_affect",
            "Decision affect must reference a subject id or repo.* identifier: #{affect}",
            decision_id,
            file
          )
          | acc
        ]
      end
    end)
  end

  defp add_decision_supersession_findings(findings, meta, decision_ids, decision_id, file) do
    status = string_field(meta, "status")
    superseded_by = string_field(meta, "superseded_by")

    cond do
      status == "superseded" and superseded_by == "" ->
        [
          finding(
            "error",
            "decision_missing_superseded_by",
            "Superseded decision must set superseded_by",
            decision_id,
            file
          )
          | findings
        ]

      superseded_by != "" and not MapSet.member?(decision_ids, superseded_by) ->
        [
          finding(
            "error",
            "decision_unknown_superseded_by",
            "Decision superseded_by references unknown decision id: #{superseded_by}",
            decision_id,
            file
          )
          | findings
        ]

      true ->
        findings
    end
  end

  defp duplicate_subject_id_findings(subjects) do
    subjects
    |> Enum.map(fn subject -> subject |> subject_meta() |> id_of("id") end)
    |> Enum.reject(&is_nil/1)
    |> duplicates()
    |> Enum.map(fn id ->
      finding("error", "duplicate_subject_id", "Duplicate subject id: #{id}", id, nil)
    end)
  end

  defp duplicate_requirement_id_findings(subjects) do
    subjects
    |> Enum.flat_map(fn subject -> list_field(subject, "requirements") end)
    |> Enum.map(&id_of(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> duplicates()
    |> Enum.map(fn id ->
      finding("error", "duplicate_requirement_id", "Duplicate requirement id: #{id}", nil, nil)
    end)
  end

  defp duplicate_scenario_id_findings(subjects) do
    subjects
    |> Enum.flat_map(fn subject -> list_field(subject, "scenarios") end)
    |> Enum.map(&id_of(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> duplicates()
    |> Enum.map(fn id ->
      finding("error", "duplicate_scenario_id", "Duplicate scenario id: #{id}", nil, nil)
    end)
  end

  defp duplicate_exception_id_findings(subjects) do
    subjects
    |> Enum.flat_map(fn subject -> list_field(subject, "exceptions") end)
    |> Enum.map(&id_of(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> duplicates()
    |> Enum.map(fn id ->
      finding("error", "duplicate_exception_id", "Duplicate exception id: #{id}", nil, nil)
    end)
  end

  defp duplicate_decision_id_findings(decisions) do
    decisions
    |> Enum.map(fn decision -> decision |> decision_meta() |> id_of("id") end)
    |> Enum.reject(&is_nil/1)
    |> duplicates()
    |> Enum.map(fn id ->
      finding("error", "duplicate_decision_id", "Duplicate decision id: #{id}", id, nil)
    end)
  end

  defp invalid_id_format_findings(subjects, decisions) do
    subject_findings =
      Enum.flat_map(subjects, fn subject ->
        meta = subject_meta(subject)
        subject_id = id_of(meta, "id")
        file = string_field(subject, "file")

        all_ids =
          [{subject_id, "subject"}] ++
            ids_from(field(subject, "requirements"), "requirement") ++
            ids_from(field(subject, "scenarios"), "scenario") ++
            ids_from(field(subject, "exceptions"), "exception")

        all_ids
        |> Enum.reject(fn {id, _kind} -> is_nil(id) end)
        |> Enum.reject(fn {id, _kind} -> Regex.match?(@id_pattern, id) end)
        |> Enum.map(fn {id, kind} ->
          finding(
            "error",
            "invalid_id_format",
            "Invalid #{kind} id format: #{id} (must match #{inspect(Regex.source(@id_pattern))})",
            subject_id,
            file
          )
        end)
      end)

    decision_findings =
      Enum.flat_map(decisions, fn decision ->
        meta = decision_meta(decision)
        decision_id = id_of(meta, "id")
        file = string_field(decision, "file")

        [decision_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&Regex.match?(@id_pattern, &1))
        |> Enum.map(fn id ->
          finding(
            "error",
            "invalid_id_format",
            "Invalid decision id format: #{id} (must match #{inspect(Regex.source(@id_pattern))})",
            decision_id,
            file
          )
        end)
      end)

    subject_findings ++ decision_findings
  end

  defp build_subject_ids(subjects) do
    subjects
    |> Enum.map(fn subject -> subject |> subject_meta() |> id_of("id") end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp build_decision_ids(decisions) do
    decisions
    |> Enum.map(fn decision -> decision |> decision_meta() |> id_of("id") end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp valid_iso_date?(date) do
    match?({:ok, _date}, Date.from_iso8601(date))
  rescue
    _ -> false
  end

  defp valid_decision_affect?(affect, subject_ids, claim_ids) do
    is_binary(affect) and affect != "" and
      (MapSet.member?(subject_ids, affect) or
         MapSet.member?(claim_ids, affect) or
         String.starts_with?(affect, "repo."))
  end

  defp ids_from(items, kind) when is_list(items) do
    Enum.map(items, fn item -> {id_of(item, "id"), kind} end)
  end

  defp ids_from(_, _kind), do: []

  defp build_command_results(_subjects, _tag_map, _root, false, _timeout), do: %{}

  defp build_command_results(subjects, tag_map, root, true, timeout_ms) do
    per_command = build_per_command_results(subjects, root, timeout_ms)
    merged = merged_tagged_tests_results(subjects, tag_map, root, timeout_ms)
    Map.merge(per_command, merged)
  end

  defp build_per_command_results(subjects, root, timeout_ms) do
    Enum.reduce(subjects, %{}, fn subject, acc ->
      file = string_field(subject, "file")
      meta = subject_meta(subject)
      subject_id = id_of(meta, "id") || file

      subject
      |> field("verification")
      |> map_items()
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {verification, idx}, inner_acc ->
        case command_result(verification, root, timeout_ms) do
          nil -> inner_acc
          result -> Map.put(inner_acc, verification_key(subject_id, file, idx), result)
        end
      end)
    end)
  end

  defp merged_tagged_tests_results(subjects, tag_map, root, timeout_ms) do
    case TaggedTests.collect_entries(subjects) do
      [] ->
        %{}

      entries ->
        cover_ids = entries |> Enum.flat_map(& &1.covers) |> Enum.uniq()

        {result, attribution} =
          case TaggedTests.build_command(cover_ids, tag_map) do
            :no_tests ->
              {%{output: "No @tag spec entries found for covers", exit_code: 0, command: nil},
               nil}

            {:ok, cmd} ->
              run_merged_command(cmd, root, timeout_ms, cover_ids, tag_map)
          end

        {result, attribution} =
          maybe_resume_after_timeout(result, attribution, root, timeout_ms, tag_map)

        result = Map.put(result, :tagged_tests_shared_count, length(entries))

        Enum.reduce(entries, %{}, fn entry, acc ->
          Map.put(acc, entry.key, entry_result(result, attribution, entry.covers))
        end)
    end
  end

  # Runs the merged command with a streaming attribution artifact. The artifact
  # path is passed to the child via SPECLED_ATTRIBUTION_PATH so the shipped
  # SpecLedEx.TaggedTests.Formatter can record per-test evidence, then read back
  # and deleted. A missing/unreadable artifact yields `nil` attribution, which
  # keeps every downstream branch on today's shared-fate path (degradation
  # contract — see specled.decision.evidence_based_attribution).
  defp run_merged_command(cmd, root, timeout_ms, cover_ids, tag_map) do
    artifact_path =
      Path.join(System.tmp_dir!(), "specled_attr_#{System.unique_integer([:positive])}.jsonl")

    try do
      base =
        cmd
        |> run_command(root, timeout_ms, env: [{"SPECLED_ATTRIBUTION_PATH", artifact_path}])
        |> Map.put(:command, cmd)

      case Attribution.read_artifact(artifact_path) do
        {:ok, events} ->
          cover_locations = cover_locations(cover_ids, tag_map, root)

          {Map.put(base, :attribution_empty, events == []),
           Attribution.attribute(events, cover_ids, cover_locations)}

        :absent ->
          {base, nil}
      end
    after
      File.rm(artifact_path)
    end
  end

  # Single resume pass over the never-started remainder after a merged-run
  # timeout. Triggers only when the first run carried the timeout fact, its
  # artifact was readable (attribution present), and it left cover ids that
  # never started. Those never-started ids are re-run exactly once, with a fresh
  # full timeout budget and a second artifact; in-flight hang suspects are
  # deliberately excluded, since re-running a hanger would just burn the second
  # budget. The resume outcomes are merged into the first run's — first-run
  # evidence wins for observed covers, the resume fills the remainder — and the
  # merged run's timeout state is recomputed. Any first-run state that misses
  # the trigger (no timeout, degraded/absent artifact, empty remainder, or no
  # backing tests for the remainder) falls back to the first-run result
  # unchanged. See specled.decision.evidence_based_attribution.
  defp maybe_resume_after_timeout(result, attribution, root, timeout_ms, tag_map) do
    remainder = not_started_cover_ids(attribution)

    if command_timed_out?(result) and is_map(attribution) and remainder != [] do
      case TaggedTests.build_command(remainder, tag_map) do
        :no_tests ->
          {result, attribution}

        {:ok, resume_cmd} ->
          {resume_result, resume_attribution} =
            run_merged_command(resume_cmd, root, timeout_ms, remainder, tag_map)

          merged = Attribution.merge(attribution, resume_attribution || %{})
          {resumed_result(result, resume_result, resume_attribution, merged), merged}
      end
    else
      {result, attribution}
    end
  end

  defp not_started_cover_ids(attribution) when is_map(attribution) do
    for {cover_id, :not_started} <- attribution, do: cover_id
  end

  defp not_started_cover_ids(_), do: []

  # Overlays the resume pass's facts onto the first run's result. The merged run
  # still counts as timed out when the resume pass itself timed out or when the
  # merged attribution still holds in-flight hang suspects (a first-run hanger we
  # chose not to re-run). `resume_in_flight` records the resume pass's own hang
  # suspects so a double timeout can name them as the likely problem.
  defp resumed_result(first_result, resume_result, resume_attribution, merged) do
    first_result
    |> Map.put(
      :timed_out,
      command_timed_out?(resume_result) or attributed_hang_suspects(merged) != []
    )
    |> Map.put(:resume_timed_out, command_timed_out?(resume_result))
    |> Map.put(:resume_in_flight, attributed_hang_suspects(resume_attribution || %{}))
  end

  # Maps each cover id to the `{absolute_file, test_line}` locations the tag
  # scanner recorded for it, in the same form the formatter records events. The
  # formatter runs with cwd = root and stores absolute file paths, so relative
  # scanner paths are expanded against root. Entries without a resolvable line
  # cannot match a real event and are dropped.
  defp cover_locations(cover_ids, tag_map, root) do
    Map.new(cover_ids, fn cover_id ->
      locations =
        tag_map
        |> Map.get(cover_id, [])
        |> Enum.flat_map(&tag_entry_location(&1, root))
        |> Enum.uniq()

      {cover_id, locations}
    end)
  end

  defp tag_entry_location(entry, root) when is_map(entry) do
    file = Map.get(entry, :file) || Map.get(entry, "file")
    line = Map.get(entry, :test_line) || Map.get(entry, "test_line")

    if is_binary(file) and is_integer(line) do
      [{Path.expand(file, root), line}]
    else
      []
    end
  end

  defp tag_entry_location(_entry, _root), do: []

  defp entry_result(result, nil, _covers), do: result

  defp entry_result(result, attribution, covers),
    do: Map.put(result, :attribution, Map.take(attribution, covers))

  # Captures command output via temp files instead of pipe-based System.cmd.
  # OTP's erl_child_setup retains pipe write-end fds for the BEAM's lifetime,
  # preventing EOF on System.cmd's read end after the child exits.
  # See: specled.decision.tempfile_command_execution
  defp command_result(verification, root, timeout_ms) do
    if runnable_command_verification?(verification) do
      target = string_field(verification, "target")
      run_command(target, root, timeout_ms)
    end
  end

  defp run_command(target, root, timeout_ms, opts \\ []) do
    tmp_out = Path.join(System.tmp_dir!(), "specled_cmd_#{System.unique_integer([:positive])}")

    # Write a wrapper script to avoid shell escaping issues with nested quotes.
    # The script captures stdout/stderr to a temp file and exits with the command status.
    tmp_script = "#{tmp_out}.sh"
    tmp_target = "#{tmp_out}.target.sh"
    tmp_pgid = "#{tmp_out}.pgid"

    # The backgrounded target must land in its own process group whose pgid
    # equals `$!`, so that on timeout we can SIGKILL the whole group and reap
    # grandchildren the target spawned — Port.close alone only kills the
    # direct child and orphans the rest. `setsid` (universal on Linux) is
    # preferred: dash, ubuntu's /bin/sh, rejects `set -m` in a tty-less
    # script ("can't access tty; job control turned off"), leaving the child
    # in the wrapper's group where the group kill misses it. macOS has no
    # setsid binary, but its bash-as-sh honors `set -m` job control, so that
    # remains the fallback (stderr-silenced for shells that reject it).
    # The target runs from its own script file rather than a subshell so both
    # branches spawn the identical unit. `wait $!` propagates the target's
    # own exit status, preserving specled.verify.command_exit_code_recorded.
    # `wait`'s stderr is silenced so the shell's "Killed: 9" job-control
    # notification for a SIGKILLed group does not leak into CLI output on
    # timeout; the exit status it returns is unaffected.
    File.write!(tmp_target, """
    #!/bin/sh
    cd "#{root}" || exit 127
    #{target}
    """)

    File.write!(tmp_script, """
    #!/bin/sh
    if command -v setsid >/dev/null 2>&1; then
      setsid /bin/sh "#{tmp_target}" > "#{tmp_out}" 2>&1 &
    else
      set -m 2>/dev/null
      /bin/sh "#{tmp_target}" > "#{tmp_out}" 2>&1 &
    fi
    echo $! > "#{tmp_pgid}"
    wait $! 2>/dev/null
    """)

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, :exit_status, {:args, [tmp_script]}] ++ port_env_opts(opts)
      )

    try do
      exit_status =
        receive do
          {^port, {:exit_status, status}} -> status
        after
          timeout_ms ->
            kill_process_group(tmp_pgid)
            close_port(port)
            :timeout
        end

      output =
        case File.read(tmp_out) do
          {:ok, data} -> data
          {:error, _} -> ""
        end

      timed_out? = exit_status == :timeout
      exit_code = if(timed_out?, do: nil, else: exit_status)

      %{output: output, exit_code: exit_code, timed_out: timed_out?, timeout_ms: timeout_ms}
    after
      File.rm(tmp_out)
      File.rm(tmp_script)
      File.rm(tmp_target)
      File.rm(tmp_pgid)
    end
  end

  # SIGKILLs the target's process group recorded by the job-control wrapper.
  # Tolerates a missing or empty pgid file (the timeout raced the wrapper's
  # first lines): close_port/1 then handles the direct child alone.
  defp kill_process_group(tmp_pgid) do
    with {:ok, data} <- File.read(tmp_pgid),
         {pgid, _rest} when pgid > 0 <- Integer.parse(String.trim(data)) do
      System.cmd("kill", ["-KILL", "--", "-#{pgid}"], stderr_to_stdout: true)
      :ok
    else
      _ -> :ok
    end
  end

  # Killing the process group makes the wrapper's `wait` return, so the port may
  # auto-close (on child exit) before this call and Port.close/1 would raise.
  # Tolerate that; the close still fires in the fallback where the pgid was
  # unavailable and the wrapper is left running.
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Translates a keyword `:env` option into the `Port.open/2` `{:env, ...}` form
  # (charlist name/value pairs). Absent or empty → no env override, so the
  # kind: command path (which never passes :env) stays inert.
  defp port_env_opts(opts) do
    case Keyword.get(opts, :env) do
      env when is_list(env) and env != [] ->
        [{:env, Enum.map(env, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)}]

      _ ->
        []
    end
  end

  defp verification_entries(subject, subject_id, file, command_results) do
    subject
    |> field("verification")
    |> map_items()
    |> Enum.with_index()
    |> Enum.map(fn {verification, idx} ->
      %{
        index: idx,
        item: verification,
        command_result: Map.get(command_results, verification_key(subject_id, file, idx))
      }
    end)
  end

  defp verification_key(subject_id, file, idx), do: {subject_id, file, idx}

  defp build_verification_claims(
         subjects,
         root,
         command_results,
         global_claim_ids,
         tag_map,
         cli_minimum_strength
       ) do
    subjects
    |> Enum.flat_map(fn subject ->
      file = string_field(subject, "file")
      meta = subject_meta(subject)
      subject_id = id_of(meta, "id") || file
      minimum_strength = effective_minimum_strength(meta, cli_minimum_strength)

      subject
      |> verification_entries(subject_id, file, command_results)
      |> Enum.flat_map(fn entry ->
        build_entry_claims(
          entry,
          root,
          subject_id,
          file,
          global_claim_ids,
          tag_map,
          minimum_strength
        )
      end)
    end)
    |> Enum.sort_by(fn claim ->
      {
        claim["subject_id"] || "",
        claim["file"] || "",
        claim["verification_index"] || 0,
        claim["cover_id"] || ""
      }
    end)
  end

  defp build_entry_claims(
         entry,
         root,
         subject_id,
         file,
         global_claim_ids,
         tag_map,
         minimum_strength
       ) do
    verification = entry.item
    kind = string_field(verification, "kind")

    if known_verification_kind?(kind) do
      verification
      |> valid_cover_ids()
      |> Enum.filter(&MapSet.member?(global_claim_ids, &1))
      |> Enum.map(fn cover_id ->
        %{
          "subject_id" => subject_id,
          "file" => file,
          "verification_index" => entry.index,
          "kind" => kind,
          "target" => string_field(verification, "target"),
          "cover_id" => cover_id,
          "strength" =>
            claim_strength(verification, entry.command_result, root, tag_map, cover_id),
          "required_strength" => minimum_strength
        }
      end)
      |> Enum.map(fn claim ->
        Map.put(
          claim,
          "meets_minimum",
          VerificationStrength.meets_minimum?(claim["strength"], claim["required_strength"])
        )
      end)
    else
      []
    end
  end

  defp effective_minimum_strength(meta, cli_minimum_strength) do
    cond do
      cli_minimum_strength ->
        cli_minimum_strength

      true ->
        case VerificationStrength.normalize(string_field(meta, "verification_minimum_strength")) do
          {:ok, normalized} when is_binary(normalized) -> normalized
          _ -> VerificationStrength.default()
        end
    end
  end

  defp claim_strength(verification, command_result, root, tag_map, cover_id) do
    kind = string_field(verification, "kind")

    cond do
      kind == @command_kind and executable_command_succeeded?(verification, command_result) ->
        "executed"

      kind == @tagged_tests_kind and
          tagged_tests_executed?(verification, command_result, tag_map, cover_id) ->
        "executed"

      kind == @tagged_tests_kind and Map.has_key?(tag_map, cover_id) ->
        "linked"

      kind in @file_kinds and verification_target_mentions_cover?(verification, root, cover_id) ->
        "linked"

      true ->
        "claimed"
    end
  end

  defp tagged_tests_executed?(verification, command_result, tag_map, cover_id) do
    bool_field(verification, "execute") and
      Map.has_key?(tag_map, cover_id) and
      is_map(command_result) and
      cover_executed?(command_result, cover_id)
  end

  # With attribution present, `executed` requires positive per-cover evidence
  # (a recorded pass, no recorded failure) even when the run as a whole was
  # killed. Without attribution (degradation), today's aggregated exit-zero
  # check applies byte-for-byte.
  defp cover_executed?(command_result, cover_id) do
    case Map.get(command_result, :attribution) do
      nil -> Map.get(command_result, :exit_code) == 0
      attribution -> Map.get(attribution, cover_id) == :passed
    end
  end

  defp executable_command_succeeded?(verification, command_result) do
    bool_field(verification, "execute") and
      string_field(verification, "target") != "" and
      is_map(command_result) and
      Map.get(command_result, :exit_code) == 0
  end

  defp verification_target_mentions_cover?(verification, root, cover_id) do
    target = string_field(verification, "target")

    if target == "" do
      false
    else
      full_path = Path.expand(target, root)

      case File.read(full_path) do
        {:ok, content} -> String.contains?(content, cover_id)
        {:error, _} -> false
      end
    end
  end

  defp verification_strength_findings(claims) do
    Enum.flat_map(claims, fn claim ->
      if claim["meets_minimum"] do
        []
      else
        [
          finding(
            "error",
            "verification_strength_below_minimum",
            "Verification strength #{claim["strength"]} is below required #{claim["required_strength"]} for #{claim["cover_id"]}",
            claim["subject_id"],
            claim["file"]
          )
        ]
      end
    end)
  end

  defp verification_report(claims, cli_minimum_strength) do
    %{
      "default_minimum_strength" => VerificationStrength.default(),
      "cli_minimum_strength" => cli_minimum_strength,
      "strength_summary" => strength_summary(claims),
      "threshold_failures" => Enum.count(claims, &(not &1["meets_minimum"])),
      "claims" => claims
    }
  end

  defp strength_summary(claims) do
    Enum.reduce(VerificationStrength.levels(), %{}, fn level, acc ->
      Map.put(acc, level, Enum.count(claims, &(&1["strength"] == level)))
    end)
  end

  defp coverage_counting_verification?(verification) do
    known_verification_kind?(string_field(verification, "kind"))
  end

  defp runnable_command_verification?(verification) do
    kind = string_field(verification, "kind")
    target = string_field(verification, "target")
    execute? = bool_field(verification, "execute")

    kind == @command_kind and execute? and target != "" and valid_covers_field?(verification)
  end

  defp valid_covers_field?(verification) do
    case field(verification, "covers") do
      covers when is_list(covers) -> Enum.all?(covers, &is_binary/1)
      _ -> false
    end
  end

  defp valid_cover_ids(verification) do
    case field(verification, "covers") do
      covers when is_list(covers) -> Enum.filter(covers, &is_binary/1)
      _ -> []
    end
  end

  defp coverage_items(verifications, exceptions) do
    verifications
    |> Enum.filter(&coverage_counting_verification?(&1.item))
    |> Enum.map(& &1.item)
    |> Kernel.++(exceptions)
  end

  defp map_items(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp map_items(_items), do: []

  defp list_field(item, key) when is_map(item) do
    case field(item, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp list_field(_item, _key), do: []

  defp string_field(item, key) when is_map(item) do
    case field(item, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp string_field(_item, _key), do: ""

  defp bool_field(item, key) when is_map(item), do: field(item, key) == true
  defp bool_field(_item, _key), do: false

  defp known_verification_kind?(kind), do: kind in @known_verification_kinds

  defp normalize_minimum_strength!(nil), do: nil

  defp normalize_minimum_strength!(value) do
    case VerificationStrength.normalize(value) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        raise ArgumentError, "invalid min_strength: #{message}"
    end
  end

  defp apply_severity_overrides(findings, overrides) when is_map(overrides) do
    Enum.flat_map(findings, fn finding ->
      case severity_override(overrides, finding["code"]) do
        :off ->
          []

        severity when severity in [:info, :warning, :error] ->
          [Map.put(finding, "severity", Atom.to_string(severity))]

        severity when severity in ["info", "warning", "error"] ->
          [Map.put(finding, "severity", severity)]

        _ ->
          [finding]
      end
    end)
  end

  defp apply_severity_overrides(findings, _overrides), do: findings

  defp severity_override(overrides, code) when is_binary(code) do
    atom_key =
      try do
        String.to_existing_atom(code)
      rescue
        ArgumentError -> nil
      end

    Map.get(overrides, code, if(atom_key, do: Map.get(overrides, atom_key)))
  end

  defp severity_override(_overrides, _code), do: nil

  defp display_kind(""), do: "<empty>"
  defp display_kind(kind), do: kind

  defp sort_findings(findings) do
    Enum.sort_by(findings, fn finding ->
      {
        finding["file"] || "",
        finding["subject_id"] || "",
        finding["code"] || "",
        finding["message"] || ""
      }
    end)
  end

  defp sort_checks(checks) do
    Enum.sort_by(checks, fn check ->
      {
        check["file"] || "",
        check["subject_id"] || "",
        check["code"] || "",
        check["message"] || "",
        check["status"] || ""
      }
    end)
  end

  defp present_string?(item, key) do
    case string_field(item, key) do
      "" -> false
      value -> String.trim(value) != ""
    end
  end

  defp subject_meta(subject) when is_map(subject) do
    case field(subject, "meta") do
      meta when is_map(meta) -> meta
      _ -> %{}
    end
  end

  defp subject_meta(_subject), do: %{}

  defp decision_meta(decision) when is_map(decision) do
    case field(decision, "meta") do
      meta when is_map(meta) -> meta
      _ -> %{}
    end
  end

  defp decision_meta(_decision), do: %{}

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp id_of(item, key) when is_map(item) do
    case field(item, key) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp id_of(_item, _key), do: nil

  defp field(item, key) when is_map(item) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(item, key, if(atom_key, do: Map.get(item, atom_key)))
  end

  defp field(_item, _key), do: nil

  defp finding(severity, code, message, subject_id, file) do
    %{
      "severity" => severity,
      "code" => code,
      "message" => message,
      "subject_id" => subject_id,
      "file" => file
    }
  end

  defp check(status, code, message, subject_id, file) do
    %{
      "status" => status,
      "code" => code,
      "message" => message,
      "subject_id" => subject_id,
      "file" => file
    }
  end
end
