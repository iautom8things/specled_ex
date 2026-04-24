defmodule SpecLedEx.TaggedTests do
  @moduledoc false

  @kind "tagged_tests"
  @base_command "mix test"
  @include_integration_flag "--include integration"

  @type entry :: %{key: {String.t(), String.t(), non_neg_integer()}, covers: [String.t()]}

  @doc "Returns the verification kind name used for tagged tests."
  def kind, do: @kind

  @doc "Returns the base command (without flags or files) used when aggregating tagged_tests runs."
  def base_command, do: @base_command

  @doc "Returns the `--include integration` flag appended to merged commands."
  def include_integration_flag, do: @include_integration_flag

  @doc """
  Collects every executable `tagged_tests` verification across the given subjects.

  Each returned entry carries a stable `key` (matching the verifier's
  `verification_key/3` tuple shape) and the list of cover ids declared on that
  verification.
  """
  @spec collect_entries([map()]) :: [entry()]
  def collect_entries(subjects) when is_list(subjects) do
    Enum.flat_map(subjects, fn subject ->
      file = string_field(subject, "file")
      meta = subject_meta(subject)
      subject_id = id_of(meta, "id") || file

      subject
      |> field("verification")
      |> filter_maps()
      |> Enum.with_index()
      |> Enum.flat_map(fn {verification, idx} ->
        if string_field(verification, "kind") == @kind and
             bool_field(verification, "execute") do
          [
            %{
              key: {subject_id, file, idx},
              covers: valid_cover_ids(verification)
            }
          ]
        else
          []
        end
      end)
    end)
  end

  @doc """
  Builds the aggregated `mix test` command for the given cover ids, using
  `tag_map` to look up test file paths and to drop ids that have no
  `@tag spec:` annotation.

  The emitted command always appends `--include integration` so that host
  projects which configure `ExUnit.configure(exclude: :integration)` still
  execute integration-tagged tests that participate in a merged run. With
  ExUnit's default filter behaviour the flag is a no-op; it is a defensive
  marker for host projects that opt into exclusion.

  Returns `{:ok, command}` when at least one cover id is present in `tag_map`,
  or `:no_tests` when none of the ids are tagged.
  """
  @spec build_command([String.t()], map()) :: {:ok, String.t()} | :no_tests
  def build_command(cover_ids, tag_map) when is_list(cover_ids) and is_map(tag_map) do
    resolved = Enum.filter(cover_ids, &Map.has_key?(tag_map, &1))

    case resolved do
      [] ->
        :no_tests

      _ ->
        only_flags = Enum.map(resolved, &"--only spec:#{&1}")

        files =
          resolved
          |> Enum.flat_map(fn id ->
            case Map.get(tag_map, id) do
              entries when is_list(entries) ->
                Enum.map(entries, &tag_entry_file/1)

              _ ->
                []
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        command_parts = [@base_command | only_flags] ++ [@include_integration_flag] ++ files

        {:ok, Enum.join(command_parts, " ")}
    end
  end

  defp tag_entry_file(entry) when is_map(entry),
    do: Map.get(entry, :file) || Map.get(entry, "file")

  defp tag_entry_file(_), do: nil

  defp field(item, key) when is_map(item) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(item, key, if(atom_key, do: Map.get(item, atom_key)))
  end

  defp field(_, _), do: nil

  defp filter_maps(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp filter_maps(_), do: []

  defp subject_meta(subject) when is_map(subject) do
    case field(subject, "meta") do
      meta when is_map(meta) -> meta
      _ -> %{}
    end
  end

  defp subject_meta(_), do: %{}

  defp id_of(map, key) when is_map(map) do
    case field(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp id_of(_, _), do: nil

  defp string_field(item, key) when is_map(item) do
    case field(item, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp string_field(_, _), do: ""

  defp bool_field(item, key) when is_map(item), do: field(item, key) == true
  defp bool_field(_, _), do: false

  defp valid_cover_ids(verification) do
    case field(verification, "covers") do
      covers when is_list(covers) -> Enum.filter(covers, &is_binary/1)
      _ -> []
    end
  end
end
