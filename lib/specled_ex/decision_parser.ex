defmodule SpecLedEx.DecisionParser do
  @moduledoc false

  alias SpecLedEx.DecisionParser.CrossField

  @frontmatter_pattern ~r/\A---\s*\n(.*?)\n---\s*(?:\n|$)(.*)\z/ms
  @required_sections ~w(Context Decision Consequences)

  def parse_file(path, root) do
    parse_file(path, root, nil, [])
  end

  @doc """
  Parses a single ADR file, optionally running CrossField validation when a
  `current_index` is supplied.

  Signature: `parse_file(path, root, current_index \\\\ nil, opts \\\\ [])`.

  When `current_index` is `nil`, behaviour matches the 2-arity parse_file
  (frontmatter + sections only; no cross-field validation). When supplied,
  `CrossField.validate/3` runs after frontmatter parse and its errors are
  threaded into `"parse_errors"` alongside any frontmatter errors.

  `opts` accepts `:prior_decisions` (a list of prior-state decision maps)
  which is forwarded to `CrossField.validate/3` for rule R5 (ADR
  append-only).
  """
  def parse_file(path, root, current_index, opts) do
    content = File.read!(path)

    decision =
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

    maybe_run_cross_field(decision, current_index, opts)
  end

  def required_sections, do: @required_sections

  @doc """
  Runs `CrossField.validate/3` over every decision in `decisions` and
  returns the list with cross-field errors merged into each decision's
  `"parse_errors"`.

  Caller supplies `current_index` (a map carrying `"subjects"` and
  `"decisions"` keys) and may pass `:prior_decisions` through `opts` to
  enable rule R5.
  """
  def validate_cross_fields(decisions, current_index, opts \\ []) when is_list(decisions) do
    Enum.map(decisions, fn decision ->
      maybe_run_cross_field(decision, current_index, opts)
    end)
  end

  defp maybe_run_cross_field(decision, nil, _opts), do: decision

  # Severity is carried structurally, not encoded in the message: error-severity
  # rules land in `"parse_errors"` (which the verifier reports as errors) and
  # warning-severity rules land in `"parse_warnings"`. Folding warnings into
  # `"parse_errors"` would turn every `change_type:`-less legacy ADR into a hard
  # parse error, which `specled.decisions.change_type_optional` forbids.
  defp maybe_run_cross_field(decision, current_index, opts) do
    decision
    |> CrossField.validate(current_index, opts)
    |> Enum.reduce(decision, fn
      %{severity: :warning} = warning, acc ->
        push_parse_warning(acc, format_cross_field_diagnostic(warning))

      error, acc ->
        push_parse_error(acc, format_cross_field_diagnostic(error))
    end)
  end

  defp format_cross_field_diagnostic(%{code: code, message: message}) do
    "#{code}: #{message}"
  end

  defp base_decision(path, root, content) do
    %{
      "file" => Path.relative_to(path, root),
      "title" => extract_title(content),
      "meta" => nil,
      "sections" => [],
      "parse_errors" => [],
      "parse_warnings" => []
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

  # Map.update/4, not update!/3: `validate_cross_fields/3` also runs over
  # decisions parsed before this key existed (base-tree views, cached indexes).
  defp push_parse_warning(decision, message) do
    Map.update(decision, "parse_warnings", [message], &[message | &1])
  end
end
