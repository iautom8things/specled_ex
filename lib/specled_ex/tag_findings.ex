defmodule SpecLedEx.TagFindings do
  @moduledoc false

  @test_file_kinds ["test_file", "test"]
  @tagged_tests_kind "tagged_tests"

  def findings(index) do
    case Map.get(index, "test_tags") do
      nil ->
        []

      tag_map when is_map(tag_map) ->
        subjects = index["subjects"] || []
        severity = severity_from_config(Map.get(index, "test_tags_config"))

        parse_error_findings(Map.get(index, "test_tags_errors") || []) ++
          dynamic_value_findings(Map.get(index, "test_tags_dynamic") || []) ++
          requirement_without_tag_findings(subjects, tag_map, severity) ++
          verification_cover_untagged_findings(subjects, tag_map, severity)
    end
  end

  defp severity_from_config(%{"enforcement" => "error"}), do: "error"
  defp severity_from_config(_), do: "warning"

  defp parse_error_findings(entries) do
    Enum.map(entries, fn entry ->
      file = fetch(entry, :file) || fetch(entry, "file")
      reason = fetch(entry, :reason) || fetch(entry, "reason")

      finding(
        "warning",
        "tag_scan_parse_error",
        "Tag scanner could not parse #{file}: #{inspect(reason)}",
        nil,
        file
      )
    end)
  end

  defp dynamic_value_findings(entries) do
    Enum.map(entries, fn entry ->
      file = fetch(entry, :file) || fetch(entry, "file")
      line = fetch(entry, :line) || fetch(entry, "line") || 0
      test_name = fetch(entry, :test_name) || fetch(entry, "test_name")

      location =
        if test_name,
          do: "#{file}:#{line} in test #{inspect(test_name)}",
          else: "#{file}:#{line}"

      finding(
        "warning",
        "tag_dynamic_value_skipped",
        "Dynamic @tag spec value could not be resolved at #{location}",
        nil,
        file
      )
    end)
  end

  defp requirement_without_tag_findings(subjects, tag_map, severity) do
    Enum.flat_map(subjects, fn subject ->
      {subject_id, file} = subject_id_and_file(subject)
      tagged_tests_covers = tagged_tests_cover_ids(subject)

      subject
      |> list_field("requirements")
      |> Enum.filter(&map?/1)
      |> Enum.filter(&must_priority?/1)
      |> Enum.map(&string_field(&1, "id"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.filter(&MapSet.member?(tagged_tests_covers, &1))
      |> Enum.reject(&Map.has_key?(tag_map, &1))
      |> Enum.map(fn req_id ->
        finding(
          severity,
          "requirement_without_test_tag",
          "Requirement has no backing @tag spec annotation in the test suite: #{req_id}",
          subject_id,
          file
        )
      end)
    end)
  end

  defp tagged_tests_cover_ids(subject) do
    subject
    |> list_field("verification")
    |> Enum.filter(&map?/1)
    |> Enum.filter(fn v -> string_field(v, "kind") == @tagged_tests_kind end)
    |> Enum.flat_map(&list_field(&1, "covers"))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp verification_cover_untagged_findings(subjects, tag_map, severity) do
    Enum.flat_map(subjects, fn subject ->
      {subject_id, file} = subject_id_and_file(subject)

      subject
      |> list_field("verification")
      |> Enum.filter(&map?/1)
      |> Enum.filter(fn v -> string_field(v, "kind") in @test_file_kinds end)
      |> Enum.flat_map(fn verification ->
        target = string_field(verification, "target")

        if target == "" do
          []
        else
          verification
          |> list_field("covers")
          |> Enum.filter(&is_binary/1)
          |> Enum.reject(&cover_id_tagged_in?(&1, target, tag_map))
          |> Enum.map(fn cover_id ->
            finding(
              severity,
              "verification_cover_untagged",
              "Verification target #{target} has no @tag spec: #{cover_id} annotation",
              subject_id,
              file
            )
          end)
        end
      end)
    end)
  end

  defp cover_id_tagged_in?(cover_id, target, tag_map) do
    case Map.get(tag_map, cover_id) do
      entries when is_list(entries) ->
        Enum.any?(entries, fn entry -> tag_entry_file(entry) == target end)

      _ ->
        false
    end
  end

  defp tag_entry_file(entry) when is_map(entry),
    do: fetch(entry, :file) || fetch(entry, "file")

  defp tag_entry_file(_), do: nil

  defp subject_id_and_file(subject) do
    file = string_field(subject, "file")
    meta = subject_meta(subject)

    subject_id =
      case string_field(meta, "id") do
        "" -> file
        id -> id
      end

    {subject_id, file}
  end

  defp subject_meta(subject) when is_map(subject) do
    case fetch(subject, "meta") do
      meta when is_map(meta) -> meta
      _ -> %{}
    end
  end

  defp subject_meta(_), do: %{}

  defp must_priority?(requirement), do: string_field(requirement, "priority") == "must"

  defp map?(value), do: is_map(value)

  defp list_field(map, key) when is_map(map) do
    case fetch(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp list_field(_, _), do: []

  defp string_field(map, key) when is_map(map) do
    case fetch(map, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp string_field(_, _), do: ""

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key, if(atom_key, do: Map.get(map, atom_key)))
  end

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch(_, _), do: nil

  defp finding(severity, code, message, subject_id, file) do
    %{
      "severity" => severity,
      "code" => code,
      "message" => message,
      "subject_id" => subject_id,
      "file" => file
    }
  end
end
