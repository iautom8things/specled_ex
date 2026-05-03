defmodule SpecLedEx.Review.SpecDiff do
  @moduledoc false

  alias SpecLedEx.Parser

  @doc """
  Computes per-id change sets for one subject's requirements and scenarios
  between `base_ref` and the working tree.

  Returns:

      %{
        file_changed?: boolean,
        base_existed?: boolean,
        requirements: %{
          added: [item],
          modified: [%{id, head, base}],
          removed: [item],
          unchanged_ids: MapSet.t
        },
        scenarios: %{... same shape ...}
      }

  When the spec file did not exist at `base_ref`, every current requirement
  and scenario is reported as added.
  """
  def compute(root, base_ref, head_subject) do
    file = head_subject["file"]
    base_subject = parse_at_base(root, base_ref, file)
    base_existed? = not is_nil(base_subject)

    head_reqs = list_field(head_subject, "requirements")
    base_reqs = list_field(base_subject || %{}, "requirements")
    head_scenarios = list_field(head_subject, "scenarios")
    base_scenarios = list_field(base_subject || %{}, "scenarios")

    %{
      file_changed?: file_changed?(root, base_ref, file),
      base_existed?: base_existed?,
      requirements: changeset(head_reqs, base_reqs, [:statement, :priority, :stability]),
      scenarios: changeset(head_scenarios, base_scenarios, [:given, :when, :then, :covers])
    }
  end

  @doc """
  Returns `:new`, `:modified`, `:unchanged`, or `:removed` for an ADR file
  by comparing its content at `base_ref` vs. the working tree.
  """
  def adr_change_status(root, base_ref, file) do
    base = fetch_at_ref(root, base_ref, file)
    head_path = Path.join(root, file)
    head_exists? = File.exists?(head_path)

    case {base, head_exists?} do
      {:error, true} -> :new
      {:error, false} -> :unchanged
      {{:ok, _}, false} -> :removed
      {{:ok, base_content}, true} ->
        case File.read(head_path) do
          {:ok, head_content} when head_content == base_content -> :unchanged
          _ -> :modified
        end
    end
  end

  defp parse_at_base(root, base_ref, file) when is_binary(file) do
    case fetch_at_ref(root, base_ref, file) do
      {:ok, content} ->
        tmp =
          Path.join(
            System.tmp_dir!(),
            "specled_diff_#{System.unique_integer([:positive])}.spec.md"
          )

        File.write!(tmp, content)

        try do
          Parser.parse_file(tmp, Path.dirname(tmp))
        after
          File.rm(tmp)
        end

      :error ->
        nil
    end
  end

  defp parse_at_base(_root, _base_ref, _file), do: nil

  defp file_changed?(_root, _base_ref, nil), do: false

  defp file_changed?(root, base_ref, file) do
    case fetch_at_ref(root, base_ref, file) do
      {:ok, base_content} ->
        case File.read(Path.join(root, file)) do
          {:ok, head_content} -> base_content != head_content
          _ -> true
        end

      :error ->
        true
    end
  end

  defp fetch_at_ref(root, ref, file) when is_binary(ref) and is_binary(file) do
    {output, status} =
      System.cmd("git", ["-C", root, "show", "#{ref}:#{file}"], stderr_to_stdout: true)

    if status == 0, do: {:ok, output}, else: :error
  end

  defp fetch_at_ref(_, _, _), do: :error

  defp changeset(head_items, base_items, compare_keys) do
    head_by_id = index_by_id(head_items)
    base_by_id = index_by_id(base_items)

    head_ids = head_by_id |> Map.keys() |> MapSet.new()
    base_ids = base_by_id |> Map.keys() |> MapSet.new()

    added_ids = MapSet.difference(head_ids, base_ids)
    removed_ids = MapSet.difference(base_ids, head_ids)
    common_ids = MapSet.intersection(head_ids, base_ids)

    {modified_ids, unchanged_ids} =
      Enum.split_with(common_ids, fn id ->
        items_differ?(head_by_id[id], base_by_id[id], compare_keys)
      end)

    %{
      added: Enum.map(added_ids, &head_by_id[&1]),
      removed: Enum.map(removed_ids, &base_by_id[&1]),
      modified:
        Enum.map(modified_ids, fn id ->
          %{id: id, head: head_by_id[id], base: base_by_id[id]}
        end),
      unchanged_ids: MapSet.new(unchanged_ids)
    }
  end

  defp index_by_id(items) do
    items
    |> Enum.map(fn item -> {get_id(item), item} end)
    |> Enum.reject(fn {id, _} -> id == "" end)
    |> Map.new()
  end

  defp get_id(item) when is_struct(item), do: to_string(Map.get(item, :id) || "")

  defp get_id(item) when is_map(item),
    do: to_string(Map.get(item, :id) || Map.get(item, "id") || "")

  defp get_id(_), do: ""

  defp items_differ?(a, b, keys) do
    Enum.any?(keys, fn key -> get_field(a, key) != get_field(b, key) end)
  end

  defp get_field(item, key) when is_struct(item), do: Map.get(item, key)

  defp get_field(item, key) when is_map(item) do
    Map.get(item, key) || Map.get(item, Atom.to_string(key))
  end

  defp get_field(_, _), do: nil

  defp list_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
