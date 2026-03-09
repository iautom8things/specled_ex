defmodule SpecLedEx.Parser do
  @moduledoc false

  @block_pattern ~r/```(spec-meta|spec-requirements|spec-scenarios|spec-verification|spec-exceptions)\s*\n(.*?)\n```/ms

  def parse_file(path, root) do
    content = File.read!(path)

    @block_pattern
    |> Regex.scan(content)
    |> Enum.reduce(base_spec(path, root, content), fn [_, tag, raw_json], spec ->
      decode_block(spec, tag, raw_json)
    end)
  end

  defp base_spec(path, root, content) do
    %{
      "file" => Path.relative_to(path, root),
      "title" => extract_title(content),
      "meta" => nil,
      "requirements" => [],
      "scenarios" => [],
      "verification" => [],
      "exceptions" => [],
      "parse_errors" => []
    }
  end

  defp extract_title(content) do
    case Regex.run(~r/^#\s+(.+)$/m, content, capture: :all_but_first) do
      [title] -> String.trim(title)
      _ -> nil
    end
  end

  defp decode_block(spec, "spec-meta", raw_json) do
    case Jason.decode(raw_json) do
      {:ok, meta} when is_map(meta) ->
        if is_nil(spec["meta"]) do
          Map.put(spec, "meta", meta)
        else
          push_parse_error(spec, "spec-meta may only appear once per file")
        end

      {:ok, _invalid_shape} ->
        push_parse_error(spec, "spec-meta must decode to a JSON object")

      {:error, %Jason.DecodeError{} = err} ->
        push_parse_error(spec, "spec-meta JSON decode failed: #{Exception.message(err)}")

      _ ->
        push_parse_error(spec, "spec-meta JSON decode failed")
    end
  end

  defp decode_block(spec, tag, raw_json) do
    key =
      case tag do
        "spec-requirements" -> "requirements"
        "spec-scenarios" -> "scenarios"
        "spec-verification" -> "verification"
        "spec-exceptions" -> "exceptions"
      end

    case Jason.decode(raw_json) do
      {:ok, items} when is_list(items) ->
        Map.update!(spec, key, &(&1 ++ items))

      {:ok, _invalid_shape} ->
        push_parse_error(spec, "#{tag} must decode to a JSON array")

      {:error, %Jason.DecodeError{} = err} ->
        push_parse_error(spec, "#{tag} JSON decode failed: #{Exception.message(err)}")

      _ ->
        push_parse_error(spec, "#{tag} JSON decode failed")
    end
  end

  defp push_parse_error(spec, message) do
    Map.update!(spec, "parse_errors", &[message | &1])
  end
end
