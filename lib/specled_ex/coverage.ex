defmodule SpecLedEx.Coverage do
  @moduledoc false

  @file_kinds ~w(file source_file test_file guide_file readme_file workflow_file test doc workflow contract)
  @command_prefixes ~w(.spec/ lib/ test/ guides/ docs/ priv/ config/ .github/)
  @root_files ~w(README.md CHANGELOG.md AGENTS.md mix.exs)

  def subject_file_map(index, root) do
    index["subjects"]
    |> List.wrap()
    |> Enum.reduce(%{}, fn subject, acc ->
      subject_id = subject_id(subject)

      files =
        subject
        |> covered_files_for_subject(root)
        |> MapSet.new()

      Map.put(acc, subject_id, files)
    end)
  end

  def covered_files(index, root) do
    index
    |> subject_file_map(root)
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1))
  end

  def subject_ids_for_path(subject_file_map, path) do
    path = normalize_relative_path(path)

    subject_file_map
    |> Enum.reduce(MapSet.new(), fn {subject_id, files}, acc ->
      if MapSet.member?(files, path) do
        MapSet.put(acc, subject_id)
      else
        acc
      end
    end)
  end

  def category_summary(root, covered_files, prefix) do
    files = repo_files_under(root, prefix)
    covered = Enum.filter(files, &MapSet.member?(covered_files, &1))

    %{
      "covered" => length(covered),
      "total" => length(files),
      "uncovered" => files -- covered
    }
  end

  def repo_files_under(root, prefix) do
    root
    |> Path.join(prefix)
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  def subject_id(subject) do
    subject
    |> field("meta")
    |> field("id")
    |> case do
      id when is_binary(id) and id != "" -> id
      _ -> field(subject, "file") || "<unknown>"
    end
  end

  def command_path_tokens(command) when is_binary(command) do
    command
    |> String.split(~r/\s+/)
    |> Enum.map(&String.trim(&1, "\"'`()[]{}:,"))
    |> Enum.filter(&path_token?/1)
    |> Enum.map(&normalize_relative_path/1)
    |> Enum.uniq()
  end

  def command_path_tokens(_command), do: []

  def normalize_relative_path(path) do
    path
    |> Path.expand("/")
    |> Path.relative_to("/")
    |> String.trim_leading("./")
  end

  defp covered_files_for_subject(subject, root) do
    surface_files =
      subject
      |> field("meta")
      |> list_field("surface")
      |> Enum.flat_map(&expand_surface_entry(&1, root))

    verification_files =
      subject
      |> field("verification")
      |> List.wrap()
      |> Enum.flat_map(fn
        verification when is_map(verification) ->
          kind = string_field(verification, "kind")
          target = string_field(verification, "target")

          cond do
            kind in @file_kinds and target != "" ->
              [normalize_relative_path(target)]

            kind == "command" ->
              command_path_tokens(target)

            true ->
              []
          end

        _ ->
          []
      end)

    (surface_files ++ verification_files)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_surface_entry(entry, root) do
    cond do
      entry == "" ->
        []

      glob_pattern?(entry) ->
        root
        |> Path.join(entry)
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, root))

      File.dir?(Path.join(root, entry)) ->
        root
        |> Path.join(entry)
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, root))

      path_like?(entry) ->
        [normalize_relative_path(entry)]

      true ->
        []
    end
  end

  defp path_token?(token) do
    (Enum.any?(@command_prefixes, &String.starts_with?(token, &1)) or token in @root_files) and
      not String.starts_with?(token, "http")
  end

  defp path_like?(entry) do
    String.contains?(entry, "/") or entry in @root_files
  end

  defp glob_pattern?(entry) do
    String.contains?(entry, "*") or String.contains?(entry, "?") or String.contains?(entry, "[")
  end

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
end
