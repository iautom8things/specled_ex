defmodule SpecLedEx.DecisionParser do
  @moduledoc false

  @frontmatter_pattern ~r/\A---\s*\n(.*?)\n---\s*(?:\n|$)(.*)\z/ms
  @required_sections ~w(Context Decision Consequences)

  def parse_file(path, root) do
    content = File.read!(path)

    case Regex.run(@frontmatter_pattern, content, capture: :all_but_first) do
      [raw_meta, body] ->
        base_decision(path, root, content)
        |> decode_meta(raw_meta)
        |> Map.put("sections", extract_sections(body))

      _ ->
        base_decision(path, root, content)
        |> push_parse_error("decision frontmatter missing")
        |> Map.put("sections", extract_sections(content))
    end
  end

  def required_sections, do: @required_sections

  defp base_decision(path, root, content) do
    %{
      "file" => Path.relative_to(path, root),
      "title" => extract_title(content),
      "meta" => nil,
      "sections" => [],
      "parse_errors" => []
    }
  end

  defp decode_meta(decision, raw) do
    case decode_yaml(raw) do
      {:ok, meta} when is_map(meta) ->
        Map.put(decision, "meta", meta)

      {:ok, _invalid_shape} ->
        push_parse_error(decision, "decision frontmatter must decode to a mapping")

      {:error, message} ->
        push_parse_error(decision, "decision frontmatter decode failed: #{message}")
    end
  end

  defp extract_sections(content) do
    ~r/^##\s+(.+)$/m
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [heading] -> String.trim(heading) end)
  end

  defp extract_title(content) do
    case Regex.run(~r/^#\s+(.+)$/m, content, capture: :all_but_first) do
      [title] -> String.trim(title)
      _ -> nil
    end
  end

  defp decode_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, result} -> {:ok, result}
      {:error, %YamlElixir.ParsingError{message: message}} -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp push_parse_error(decision, message) do
    Map.update!(decision, "parse_errors", &[message | &1])
  end
end
