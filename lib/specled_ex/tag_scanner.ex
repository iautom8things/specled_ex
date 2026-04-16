defmodule SpecLedEx.TagScanner do
  @moduledoc false

  @type tag_entry :: %{id: String.t(), file: String.t(), line: non_neg_integer(), test_name: String.t()}
  @type dynamic_entry :: %{file: String.t(), line: non_neg_integer(), test_name: String.t() | nil}
  @type parse_error :: %{file: String.t(), reason: term()}

  @doc """
  Scans a single test file and returns its `@tag spec:` occurrences.

  Returns `{:ok, tags}` on a parseable file, or `{:ok, tags, dynamic}` when
  `:include_dynamic` is true. Returns `{:error, reason}` when the file cannot be
  parsed as Elixir.
  """
  @spec scan_file(String.t(), keyword()) ::
          {:ok, [tag_entry()]}
          | {:ok, [tag_entry()], [dynamic_entry()]}
          | {:error, term()}
  def scan_file(path, opts \\ []) do
    case File.read(path) do
      {:ok, source} ->
        parse_and_extract(path, source, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Scans each directory in `paths` for `*_test.exs` files and aggregates results.

  Returns `{:ok, tag_map, parse_errors, dynamic_entries}` where:
  - `tag_map` is `%{requirement_id => [tag_entry]}`
  - `parse_errors` is a list of `%{file, reason}` for unparseable files
  - `dynamic_entries` is a list of annotations whose value could not be resolved to a literal
  """
  @spec scan([String.t()], keyword()) ::
          {:ok, %{String.t() => [tag_entry()]}, [parse_error()], [dynamic_entry()]}
  def scan(paths, _opts \\ []) do
    test_files =
      paths
      |> List.wrap()
      |> Enum.flat_map(&expand_test_files/1)
      |> Enum.uniq()
      |> Enum.sort()

    {tag_map, parse_errors, dynamics} =
      Enum.reduce(test_files, {%{}, [], []}, fn path, {tm, pes, dyns} ->
        case scan_file(path, include_dynamic: true) do
          {:ok, tags, dynamic} ->
            tm2 = merge_tags(tm, tags)
            {tm2, pes, dyns ++ dynamic}

          {:error, reason} ->
            {tm, [%{file: path, reason: reason} | pes], dyns}
        end
      end)

    {:ok, tag_map, Enum.reverse(parse_errors), dynamics}
    |> then(fn {:ok, _tm_unused, pes, d} -> {:ok, tag_map, pes, d} end)
  end

  defp expand_test_files(path) do
    cond do
      File.regular?(path) and String.ends_with?(path, "_test.exs") -> [path]
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*_test.exs"))
      true -> []
    end
  end

  defp parse_and_extract(path, source, opts) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        {tags, dynamics} = extract(ast, path)
        tags = dedupe(tags)

        if Keyword.get(opts, :include_dynamic, false) do
          {:ok, tags, dynamics}
        else
          {:ok, tags}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Walk the AST collecting (tags, dynamics). We traverse modules and their
  # `do` blocks, tracking pending @tag attributes and module-wide @moduletag
  # attributes, emitting tag entries when we hit a `test/2` or `test/3`
  # definition.
  defp extract(ast, file) do
    modules = collect_modules(ast)

    Enum.reduce(modules, {[], []}, fn module_body, {all_tags, all_dyn} ->
      {tags, dyn} = extract_module_tags(module_body, file)
      {all_tags ++ tags, all_dyn ++ dyn}
    end)
  end

  defp collect_modules({:defmodule, _, [_name, [do: body]]}), do: [body]

  defp collect_modules({:__block__, _, items}),
    do: Enum.flat_map(items, &collect_modules/1)

  defp collect_modules(_), do: []

  defp extract_module_tags(body, file) do
    statements =
      case body do
        {:__block__, _, items} -> items
        other -> [other]
      end

    {module_ids, module_dyn} = collect_moduletags(statements, file)

    {_pending_tags, _pending_dyn, tags, dynamics} =
      Enum.reduce(statements, {[], [], [], []}, fn stmt, acc ->
        process_statement(stmt, file, module_ids, acc)
      end)

    {tags, module_dyn ++ dynamics}
  end

  defp collect_moduletags(statements, _file) do
    Enum.reduce(statements, {[], []}, fn
      {:@, _, [{:moduletag, _, [arg]}]}, {ids, dyn} ->
        case extract_spec_from_arg(arg) do
          {:ok, new_ids} -> {ids ++ new_ids, dyn}
          :not_spec -> {ids, dyn}
          {:dynamic, line} -> {ids, dyn ++ [%{file: nil, line: line, test_name: nil}]}
        end

      _, acc ->
        acc
    end)
  end

  defp process_statement({:@, _, [{:tag, meta, [arg]}]}, _file, _moduletag_ids, {pending, pending_dyn, tags, dynamics}) do
    line = Keyword.get(meta, :line, 0)

    case extract_spec_from_arg(arg) do
      {:ok, new_ids} ->
        {pending ++ Enum.map(new_ids, &{&1, line}), pending_dyn, tags, dynamics}

      :not_spec ->
        {pending, pending_dyn, tags, dynamics}

      {:dynamic, _line} ->
        {pending, [line | pending_dyn], tags, dynamics}
    end
  end

  defp process_statement({:test, meta, args}, file, moduletag_ids, {pending, pending_dyn, tags, dynamics}) do
    line = Keyword.get(meta, :line, 0)
    test_name = test_name_from_args(args)

    module_entries =
      Enum.map(moduletag_ids, fn id ->
        %{id: id, file: file, line: line, test_name: test_name}
      end)

    pending_entries =
      Enum.map(pending, fn {id, tag_line} ->
        %{id: id, file: file, line: tag_line, test_name: test_name}
      end)

    dyn_entries =
      Enum.map(pending_dyn, fn tag_line ->
        %{file: file, line: tag_line, test_name: test_name}
      end)

    {[], [], tags ++ module_entries ++ pending_entries, dynamics ++ dyn_entries}
  end

  defp process_statement(_other, _file, _moduletag_ids, acc), do: acc

  defp test_name_from_args([name | _]) when is_binary(name), do: name
  defp test_name_from_args(_), do: nil

  # Extract requirement ids from the argument of an @tag/@moduletag call.
  # Returns {:ok, [id]}, {:dynamic, line}, or :not_spec.
  defp extract_spec_from_arg(arg) do
    cond do
      kwlist?(arg) ->
        case Keyword.get(arg, :spec, :__missing__) do
          :__missing__ -> :not_spec
          value -> resolve_spec_value(value)
        end

      true ->
        :not_spec
    end
  end

  defp kwlist?(list) when is_list(list) do
    Enum.all?(list, fn
      {k, _v} when is_atom(k) -> true
      _ -> false
    end)
  end

  defp kwlist?(_), do: false

  defp resolve_spec_value(value) when is_binary(value), do: {:ok, [value]}

  defp resolve_spec_value(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:dynamic, 0}
    end
  end

  defp resolve_spec_value({_, meta, _} = _ast) when is_list(meta) do
    {:dynamic, Keyword.get(meta, :line, 0)}
  end

  defp resolve_spec_value(_), do: {:dynamic, 0}

  defp dedupe(tags) do
    Enum.uniq_by(tags, &dedupe_key/1)
  end

  defp merge_tags(map, entries) do
    Enum.reduce(entries, map, fn %{id: id} = entry, acc ->
      Map.update(acc, id, [entry], fn existing ->
        Enum.uniq_by([entry | existing], &dedupe_key/1)
      end)
    end)
  end

  defp dedupe_key(%{id: id, file: file, test_name: test_name}), do: {id, file, test_name}
end
