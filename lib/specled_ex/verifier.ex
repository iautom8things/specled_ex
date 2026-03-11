defmodule SpecLedEx.Verifier do
  @moduledoc false

  alias SpecLedEx.Schema.Verification, as: VerificationSchema
  alias SpecLedEx.VerificationStrength

  @command_kind "command"
  @file_kinds ~w(file source_file test_file guide_file readme_file workflow_file test doc workflow contract)
  @known_verification_kinds VerificationSchema.kinds()
  @id_pattern ~r/^[a-z0-9][a-z0-9._-]*$/

  def verify(index, root, opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)
    debug? = Keyword.get(opts, :debug, false)
    run_commands? = Keyword.get(opts, :run_commands, false)
    cli_minimum_strength = normalize_minimum_strength!(Keyword.get(opts, :min_strength))
    subjects = index["subjects"] || []
    decisions = index["decisions"] || []
    subject_ids = build_subject_ids(subjects)
    decision_ids = build_decision_ids(decisions)
    command_results = build_command_results(subjects, root, run_commands?)
    global_claim_ids = build_global_claim_ids(subjects)

    verification_claims =
      build_verification_claims(
        subjects,
        root,
        command_results,
        global_claim_ids,
        cli_minimum_strength
      )

    findings =
      subjects
      |> Enum.flat_map(&verify_subject(&1, root, command_results, global_claim_ids, decision_ids))
      |> then(fn subject_findings ->
        decision_findings =
          Enum.flat_map(decisions, fn decision ->
            verify_decision(decision, subject_ids, decision_ids)
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
          decision_ids
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

  defp verify_subject(subject, root, command_results, global_claim_ids, decision_ids) do
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
    |> add_verification_findings(verifications, local_claim_ids, global_claim_ids, root, subject_id, file)
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
         file
       ) do
    Enum.reduce(verifications, findings, fn entry, acc ->
      verification = entry.item

      acc
      |> add_verification_kind_findings(verification, subject_id, file)
      |> add_verification_target_findings(verification, root, subject_id, file)
      |> add_verification_cover_findings(verification, local_claim_ids, global_claim_ids, subject_id, file)
      |> add_verification_target_content_findings(verification, root, subject_id, file)
      |> add_verification_command_runtime_findings(verification, entry.command_result, subject_id, file)
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

    if kind == @command_kind and execute? and target != "" and command_result do
      %{output: output, exit_code: exit_code} = command_result

      if exit_code == 0 do
        findings
      else
        details =
          output
          |> String.trim()
          |> String.slice(0, 1000)

        [
          finding(
            "error",
            "verification_command_failed",
            "Verification command failed: #{target}\n#{details}",
            subject_id,
            file
          )
          | findings
        ]
      end
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

  defp add_verification_cover_findings(findings, verification, local_claim_ids, global_claim_ids, subject_id, file) do
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
         decision_ids
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
          decision_ids
        )
      )

    decision_checks =
      decisions
      |> Enum.flat_map(&build_decision_debug_checks(&1, subject_ids, decision_ids))

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
         decision_ids
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
      run_commands?
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
         run_commands?
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

            if exit_code == 0 do
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
            else
              details =
                output
                |> String.trim()
                |> String.slice(0, 300)

              [
                check(
                  "error",
                  "verification_command_failed",
                  "Verification command failed: #{target} #{details}",
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

  defp build_decision_debug_checks(decision, subject_ids, decision_ids) do
    file = string_field(decision, "file")
    meta = decision_meta(decision)
    decision_id = id_of(meta, "id") || file

    []
    |> add_decision_meta_debug_checks(meta, decision_id, file)
    |> add_decision_parse_debug_checks(list_field(decision, "parse_errors"), decision_id, file)
    |> add_decision_section_debug_checks(list_field(decision, "sections"), decision_id, file)
    |> add_decision_affects_debug_checks(meta, subject_ids, decision_id, file)
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
      [check("pass", "decision_status_valid", "Decision status valid: #{status}", decision_id, file) | checks]
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
      [check("pass", "decision_date_valid", "Decision date valid: #{date}", decision_id, file) | checks]
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
      [check("pass", "decision_parse", "Decision parsed successfully", decision_id, file) | checks]
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
          check("pass", "decision_section_present", "Decision section present: #{section}", decision_id, file)
          | acc
        ]
      else
        [
          check("error", "decision_section_missing", "Decision section missing: #{section}", decision_id, file)
          | acc
        ]
      end
    end)
  end

  defp add_decision_affects_debug_checks(checks, meta, subject_ids, decision_id, file) do
    Enum.reduce(list_field(meta, "affects"), checks, fn affect, acc ->
      if valid_decision_affect?(affect, subject_ids) do
        [check("pass", "decision_affect_valid", "Decision affect valid: #{affect}", decision_id, file) | acc]
      else
        [check("error", "decision_affect_invalid", "Decision affect invalid: #{affect}", decision_id, file) | acc]
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

  defp verify_decision(decision, subject_ids, decision_ids) do
    file = string_field(decision, "file")
    meta = decision_meta(decision)
    decision_id = id_of(meta, "id") || file

    []
    |> add_decision_meta_findings(meta, decision_id, file)
    |> add_decision_parse_error_findings(list_field(decision, "parse_errors"), decision_id, file)
    |> add_decision_section_findings(list_field(decision, "sections"), decision_id, file)
    |> add_decision_affects_findings(meta, subject_ids, decision_id, file)
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

  defp add_decision_affects_findings(findings, meta, subject_ids, decision_id, file) do
    Enum.reduce(list_field(meta, "affects"), findings, fn affect, acc ->
      if valid_decision_affect?(affect, subject_ids) do
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

  defp valid_decision_affect?(affect, subject_ids) do
    is_binary(affect) and affect != "" and
      (MapSet.member?(subject_ids, affect) or String.starts_with?(affect, "repo."))
  end

  defp ids_from(items, kind) when is_list(items) do
    Enum.map(items, fn item -> {id_of(item, "id"), kind} end)
  end

  defp ids_from(_, _kind), do: []

  defp build_command_results(_subjects, _root, false), do: %{}

  defp build_command_results(subjects, root, true) do
    Enum.reduce(subjects, %{}, fn subject, acc ->
      file = string_field(subject, "file")
      meta = subject_meta(subject)
      subject_id = id_of(meta, "id") || file

      subject
      |> field("verification")
      |> map_items()
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {verification, idx}, inner_acc ->
        case command_result(verification, root) do
          nil -> inner_acc
          result -> Map.put(inner_acc, verification_key(subject_id, file, idx), result)
        end
      end)
    end)
  end

  defp command_result(verification, root) do
    if runnable_command_verification?(verification) do
      target = string_field(verification, "target")
      {output, exit_code} = System.cmd("sh", ["-lc", target], cd: root, stderr_to_stdout: true)
      %{output: output, exit_code: exit_code}
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
        build_entry_claims(entry, root, subject_id, file, global_claim_ids, minimum_strength)
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

  defp build_entry_claims(entry, root, subject_id, file, global_claim_ids, minimum_strength) do
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
          "strength" => claim_strength(verification, entry.command_result, root, cover_id),
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

  defp claim_strength(verification, command_result, root, cover_id) do
    kind = string_field(verification, "kind")

    cond do
      kind == @command_kind and executable_command_succeeded?(verification, command_result) ->
        "executed"

      kind in @file_kinds and verification_target_mentions_cover?(verification, root, cover_id) ->
        "linked"

      true ->
        "claimed"
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
