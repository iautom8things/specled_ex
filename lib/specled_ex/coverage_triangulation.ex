defmodule SpecLedEx.CoverageTriangulation do
  # covers: specled.triangulation.pure_function
  # covers: specled.triangulation.untested_realization
  # covers: specled.triangulation.untethered_test
  # covers: specled.triangulation.underspecified_realization
  # covers: specled.triangulation.execution_reach_metric
  # covers: specled.triangulation.detector_unavailable_on_missing_coverage
  @moduledoc """
  Cross-checks the three sides of the spec/code/test triangle.

  `findings/3` is a pure function over `(coverage_records, closure_map,
  tag_index)`. It does not touch the filesystem, start processes, or consult
  Mix globals. Callers (the Mix tasks) perform the impure reads (the
  per-test coverage artifact, the closure walk, the tag scan) and hand
  normalized inputs in.

  ## Input contracts

    * `coverage_records` — either the sentinel `:no_coverage_artifact` (used
      when `.spec/_coverage/per_test.coverdata` is missing, per
      `specled.triangulation.detector_unavailable_on_missing_coverage`), or
      a list of records produced by `SpecLedEx.Coverage.Store`. Each record
      carries `:test_id`, `:file`, `:lines_hit`, `:tags`, and `:test_pid`.
    * `closure_map` — `%{subjects: %{subject_id => subject_info}}`, where
      each `subject_info` declares `:owned_files` (paths whose MFAs this
      subject owns, used to reverse-map coverage back to subjects) and a
      list of `:requirements`. Every requirement carries its id, whether
      the effective binding exists (`:binding_present?`), the set of files
      (`:closure_files`) covered by its realization closure, and the
      closure MFAs as strings (`:closure_mfas`, diagnostic only).
    * `tag_index` — `%{spec: %{requirement_id => [tag_entry]}, opt_out:
      [tag_entry]}`. Each `tag_entry` is `%{file: binary, test_name:
      binary}`. `:opt_out` carries the tests annotated with
      `@tag spec_triangulation: :indirect` (per-test opt-out from
      untethered-test emission).

  ## Emitted finding codes

    * `branch_guard_untested_realization` (severity `:warning`)
    * `branch_guard_untethered_test` (severity `:info`)
    * `branch_guard_underspecified_realization` (severity `:warning`)
    * `detector_unavailable` (severity `:info`, reason
      `:no_coverage_artifact`)

  Each finding referencing a subject carries an `"execution_reach"` field
  rendered as `"N/M (0.FF)"`, where `N` is the number of requirements with
  any exercised closure and `M` is the total requirement count for that
  subject.
  """

  @type subject_id :: String.t()
  @type requirement_id :: String.t()
  @type mfa_string :: String.t()
  @type test_tag_entry :: %{required(:file) => String.t(), required(:test_name) => String.t()}

  @type requirement_info :: %{
          required(:id) => requirement_id(),
          required(:binding_present?) => boolean(),
          required(:closure_files) => [Path.t()],
          optional(:closure_mfas) => [mfa_string()]
        }

  @type subject_info :: %{
          required(:owned_files) => [Path.t()],
          required(:requirements) => [requirement_info()]
        }

  @type closure_map :: %{required(:subjects) => %{optional(subject_id()) => subject_info()}}

  @type tag_index :: %{
          optional(:spec) => %{optional(requirement_id()) => [test_tag_entry()]},
          optional(:opt_out) => [test_tag_entry()]
        }

  @type coverage_record :: %{
          required(:test_id) => String.t(),
          required(:file) => String.t(),
          required(:lines_hit) => [non_neg_integer()],
          required(:tags) => map(),
          required(:test_pid) => pid()
        }

  @type coverage_input :: :no_coverage_artifact | [coverage_record()]

  @type finding :: map()

  @doc """
  Returns the triangulation findings for the given inputs.

  Returns a single `detector_unavailable` finding (reason
  `:no_coverage_artifact`) when `coverage_records` is
  `:no_coverage_artifact`, and otherwise computes
  `branch_guard_untested_realization`,
  `branch_guard_untethered_test`, and
  `branch_guard_underspecified_realization` findings over the inputs.
  """
  @spec findings(coverage_input(), closure_map(), tag_index()) :: [finding()]
  def findings(:no_coverage_artifact, _closure_map, _tag_index) do
    [
      %{
        "code" => "detector_unavailable",
        "severity" => "info",
        "reason" => "no_coverage_artifact",
        "message" =>
          "Per-test coverage artifact missing; run `mix spec.cover.test` to enable triangulation."
      }
    ]
  end

  def findings(records, closure_map, tag_index)
      when is_list(records) and is_map(closure_map) and is_map(tag_index) do
    subjects = Map.get(closure_map, :subjects, %{})
    spec_tags = Map.get(tag_index, :spec, %{})
    opt_out = Map.get(tag_index, :opt_out, [])
    opt_out_set = MapSet.new(opt_out, &tag_entry_key/1)

    per_test = group_records_by_test(records)
    file_to_subjects = build_file_to_subjects(subjects)
    req_to_subject = build_requirement_to_subject(subjects)
    subject_req_ids = build_subject_requirement_ids(subjects)

    reach = execution_reach(subjects, per_test)

    untested =
      untested_findings(subjects, per_test, reach)

    untethered =
      untethered_findings(
        per_test,
        spec_tags,
        opt_out_set,
        req_to_subject,
        file_to_subjects,
        reach
      )

    underspecified =
      underspecified_findings(
        per_test,
        file_to_subjects,
        subject_req_ids,
        reach
      )

    untested ++ untethered ++ underspecified
  end

  @doc """
  Returns the per-subject execution-reach map as a string → string map.

  Exposed so `mix spec.triangle` can render the metric even when no findings
  are emitted. The format is `"N/M (0.FF)"`.
  """
  @spec execution_reach_map([coverage_record()], closure_map()) :: %{subject_id() => String.t()}
  def execution_reach_map(records, closure_map)
      when is_list(records) and is_map(closure_map) do
    subjects = Map.get(closure_map, :subjects, %{})
    per_test = group_records_by_test(records)
    execution_reach(subjects, per_test)
  end

  # covers: specled.spec_review.coverage_tab_bind_closure
  @doc """
  Returns per-requirement bind-closure reach data, keyed by
  `{subject_id, requirement_id}`.

  Each entry is a map with:
    * `:closure_mfa_count` — total MFAs in the requirement's realization
      closure (length of `closure_mfas`).
    * `:closure_file_count` — total distinct files in the closure.
    * `:reached_files` — sorted list of closure files that any test
      exercised.
    * `:unreached_files` — sorted list of closure files that no test
      exercised.
    * `:reaching_tests` — sorted list of test display names
      (`"<file> :: <name>"`) that exercised at least one closure file.

  Pure: `coverage_records` is the same input contract as `findings/3`, but
  this function does not branch on `:no_coverage_artifact` — pass the
  sentinel and you'll get `:no_coverage_artifact` back so the caller can
  render a "coverage artifact unavailable" message that piggybacks the
  `:degraded` leg state machinery.
  """
  @spec per_requirement_reach(coverage_input(), closure_map()) ::
          :no_coverage_artifact
          | %{
              optional({subject_id(), requirement_id()}) => %{
                closure_mfa_count: non_neg_integer(),
                closure_file_count: non_neg_integer(),
                reached_files: [Path.t()],
                unreached_files: [Path.t()],
                reaching_tests: [String.t()]
              }
            }
  def per_requirement_reach(:no_coverage_artifact, _closure_map), do: :no_coverage_artifact

  def per_requirement_reach(records, closure_map)
      when is_list(records) and is_map(closure_map) do
    subjects = Map.get(closure_map, :subjects, %{})
    per_test = group_records_by_test(records)

    Enum.reduce(subjects, %{}, fn {subject_id, info}, acc ->
      reqs = Map.get(info, :requirements, [])

      Enum.reduce(reqs, acc, fn req, inner ->
        closure_files = req |> Map.get(:closure_files, []) |> Enum.map(&normalize_path/1)
        closure_mfa_count = req |> Map.get(:closure_mfas, []) |> length()
        closure_set = MapSet.new(closure_files)

        {reached_files, reaching_tests} =
          Enum.reduce(per_test, {MapSet.new(), MapSet.new()}, fn t, {files_acc, tests_acc} ->
            hit =
              t.files
              |> Enum.filter(&MapSet.member?(closure_set, &1))

            case hit do
              [] ->
                {files_acc, tests_acc}

              hits ->
                {
                  Enum.reduce(hits, files_acc, &MapSet.put(&2, &1)),
                  MapSet.put(tests_acc, format_test_display(t))
                }
            end
          end)

        reached_sorted = reached_files |> MapSet.to_list() |> Enum.sort()
        reaching_sorted = reaching_tests |> MapSet.to_list() |> Enum.sort()

        unreached_sorted =
          closure_files
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.reject(&MapSet.member?(reached_files, &1))

        Map.put(inner, {subject_id, req.id}, %{
          closure_mfa_count: closure_mfa_count,
          closure_file_count: closure_set |> MapSet.size(),
          reached_files: reached_sorted,
          unreached_files: unreached_sorted,
          reaching_tests: reaching_sorted
        })
      end)
    end)
  end

  defp format_test_display(%{test_file: file, test_name: name}) do
    file = if file in [nil, ""], do: "(unknown)", else: file
    name = if name in [nil, ""], do: "(anonymous)", else: name
    "#{file} :: #{name}"
  end

  # ---------------------------------------------------------------------------
  # Grouping + indexes
  # ---------------------------------------------------------------------------

  defp group_records_by_test(records) do
    records
    |> Enum.group_by(& &1.test_id)
    |> Enum.map(fn {test_id, recs} ->
      files =
        recs
        |> Enum.filter(fn r -> r.lines_hit != [] end)
        |> Enum.map(&normalize_path(&1.file))
        |> Enum.uniq()

      first = hd(recs)
      tags = Map.get(first, :tags, %{}) || %{}

      %{
        test_id: test_id,
        test_file: normalize_path(test_file_from_tags(tags)),
        test_name: Map.get(tags, :test) || Map.get(tags, "test") || "",
        files: files,
        spec_ids: extract_tag_list(tags, :spec),
        opt_out?: opt_out_tag?(tags)
      }
    end)
    |> Enum.sort_by(& &1.test_id)
  end

  defp test_file_from_tags(tags) do
    Map.get(tags, :file) || Map.get(tags, "file") || ""
  end

  defp extract_tag_list(tags, key) do
    value = Map.get(tags, key) || Map.get(tags, Atom.to_string(key))

    cond do
      is_binary(value) -> [value]
      is_list(value) -> Enum.filter(value, &is_binary/1)
      true -> []
    end
  end

  defp opt_out_tag?(tags) do
    value =
      Map.get(tags, :spec_triangulation) || Map.get(tags, "spec_triangulation")

    value == :indirect or value == "indirect"
  end

  defp build_file_to_subjects(subjects) do
    Enum.reduce(subjects, %{}, fn {subject_id, info}, acc ->
      info
      |> Map.get(:owned_files, [])
      |> Enum.reduce(acc, fn file, acc ->
        normalized = normalize_path(file)

        Map.update(acc, normalized, MapSet.new([subject_id]), &MapSet.put(&1, subject_id))
      end)
    end)
  end

  defp build_requirement_to_subject(subjects) do
    Enum.reduce(subjects, %{}, fn {subject_id, info}, acc ->
      info
      |> Map.get(:requirements, [])
      |> Enum.reduce(acc, fn req, acc ->
        Map.put(acc, req.id, subject_id)
      end)
    end)
  end

  defp build_subject_requirement_ids(subjects) do
    Map.new(subjects, fn {subject_id, info} ->
      ids =
        info
        |> Map.get(:requirements, [])
        |> Enum.map(& &1.id)
        |> MapSet.new()

      {subject_id, ids}
    end)
  end

  # ---------------------------------------------------------------------------
  # Execution reach
  # ---------------------------------------------------------------------------

  defp execution_reach(subjects, per_test) do
    exercised_files =
      per_test
      |> Enum.flat_map(& &1.files)
      |> MapSet.new()

    Map.new(subjects, fn {subject_id, info} ->
      reqs = Map.get(info, :requirements, [])
      m = length(reqs)

      n =
        Enum.count(reqs, fn req ->
          closure = req.closure_files |> Enum.map(&normalize_path/1)
          Enum.any?(closure, &MapSet.member?(exercised_files, &1))
        end)

      {subject_id, format_reach(n, m)}
    end)
  end

  defp format_reach(_n, 0), do: "0/0 (1.00)"

  defp format_reach(n, m) do
    ratio = n / m
    "#{n}/#{m} (#{:erlang.float_to_binary(ratio, decimals: 2)})"
  end

  # ---------------------------------------------------------------------------
  # Untested realization
  # ---------------------------------------------------------------------------

  defp untested_findings(subjects, per_test, reach) do
    exercised_files =
      per_test
      |> Enum.flat_map(& &1.files)
      |> MapSet.new()

    subjects
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.flat_map(fn {subject_id, info} ->
      info
      |> Map.get(:requirements, [])
      |> Enum.filter(fn req ->
        req.binding_present? and req.closure_files != [] and
          not Enum.any?(Enum.map(req.closure_files, &normalize_path/1), &MapSet.member?(
            exercised_files,
            &1
          ))
      end)
      |> Enum.map(fn req ->
        %{
          "code" => "branch_guard_untested_realization",
          "severity" => "warning",
          "subject_id" => subject_id,
          "requirement_id" => req.id,
          "closure_files" => Enum.sort(Enum.map(req.closure_files, &normalize_path/1)),
          "closure_mfas" => Enum.sort(Map.get(req, :closure_mfas, [])),
          "execution_reach" => Map.get(reach, subject_id),
          "message" =>
            "Requirement #{req.id} has a non-empty realization closure but no test " <>
              "exercised any file in the closure."
        }
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Untethered test
  # ---------------------------------------------------------------------------

  defp untethered_findings(per_test, _spec_tags, opt_out_set, req_to_subject, file_to_subjects, reach) do
    per_test
    |> Enum.reject(& &1.opt_out?)
    |> Enum.reject(fn test -> MapSet.member?(opt_out_set, {test.test_file, test.test_name}) end)
    |> Enum.flat_map(fn test ->
      observed_subjects = subjects_for_files(test.files, file_to_subjects)

      cond do
        test.spec_ids == [] ->
          []

        MapSet.size(observed_subjects) == 0 ->
          []

        true ->
          Enum.flat_map(test.spec_ids, fn req_id ->
            case Map.get(req_to_subject, req_id) do
              nil ->
                []

              expected_subject ->
                if MapSet.member?(observed_subjects, expected_subject) do
                  []
                else
                  observed = observed_subjects |> MapSet.to_list() |> Enum.sort()

                  [
                    %{
                      "code" => "branch_guard_untethered_test",
                      "severity" => "info",
                      "subject_id" => expected_subject,
                      "requirement_id" => req_id,
                      "file" => test.test_file,
                      "test_name" => test.test_name,
                      "tag" => req_id,
                      "observed_owners" => observed,
                      "execution_reach" => Map.get(reach, expected_subject),
                      "message" =>
                        "Test #{test.test_file} #{inspect(test.test_name)} is tagged " <>
                          "`@tag spec: \"#{req_id}\"` (subject #{expected_subject}) but " <>
                          "its coverage exercises only subject(s) #{Enum.join(observed, ", ")}."
                    }
                  ]
                end
            end
          end)
      end
    end)
  end

  defp subjects_for_files(files, file_to_subjects) do
    Enum.reduce(files, MapSet.new(), fn file, acc ->
      case Map.get(file_to_subjects, normalize_path(file)) do
        nil -> acc
        set -> MapSet.union(acc, set)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Underspecified realization
  # ---------------------------------------------------------------------------

  defp underspecified_findings(per_test, file_to_subjects, subject_req_ids, reach) do
    per_test
    |> Enum.flat_map(fn test ->
      observed_subjects = subjects_for_files(test.files, file_to_subjects)

      observed_subjects
      |> Enum.sort()
      |> Enum.flat_map(fn subject_id ->
        reqs = Map.get(subject_req_ids, subject_id, MapSet.new())
        tagged_for_subject? = Enum.any?(test.spec_ids, &MapSet.member?(reqs, &1))

        if tagged_for_subject? or MapSet.size(reqs) == 0 do
          []
        else
          [
            %{
              "code" => "branch_guard_underspecified_realization",
              "severity" => "warning",
              "subject_id" => subject_id,
              "file" => test.test_file,
              "test_name" => test.test_name,
              "exercised_files" =>
                Enum.sort(
                  Enum.filter(test.files, fn f ->
                    case Map.get(file_to_subjects, normalize_path(f)) do
                      nil -> false
                      set -> MapSet.member?(set, subject_id)
                    end
                  end)
                ),
              "execution_reach" => Map.get(reach, subject_id),
              "message" =>
                "Test #{test.test_file} #{inspect(test.test_name)} exercises subject " <>
                  "#{subject_id} but carries no `@tag spec:` referencing any of its " <>
                  "requirements."
            }
          ]
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tag_entry_key(%{file: f, test_name: t}), do: {normalize_path(f), t}
  defp tag_entry_key(%{"file" => f, "test_name" => t}), do: {normalize_path(f), t}
  defp tag_entry_key(other), do: other

  defp normalize_path(path) when is_binary(path) do
    path |> String.trim_leading("./")
  end

  defp normalize_path(other), do: other
end
