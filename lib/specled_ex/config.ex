defmodule SpecLedEx.Config do
  @moduledoc false

  require Logger

  defmodule TestTags do
    @moduledoc false
    defstruct enabled: false, paths: ["test"], enforcement: :warning

    @type t :: %__MODULE__{
            enabled: boolean(),
            paths: [String.t()],
            enforcement: :warning | :error
          }
  end

  defstruct test_tags: nil, diagnostics: []

  @type diagnostic :: %{kind: atom(), message: String.t()}
  @type t :: %__MODULE__{test_tags: TestTags.t(), diagnostics: [diagnostic()]}

  @doc "Returns the default configuration with no diagnostics."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{test_tags: %TestTags{}}

  @doc """
  Loads `.spec/config.yml` relative to `root`.

  Returns a `%SpecLedEx.Config{}` struct. Missing or unreadable files yield
  `defaults/0`. Malformed YAML yields defaults with a parse diagnostic recorded
  on the `:diagnostics` field. Unknown enforcement values fall back to the
  default and log a warning.
  """
  @spec load(String.t(), keyword()) :: t()
  def load(root, opts \\ []) do
    path = opts[:path] || Path.join([root, ".spec", "config.yml"])

    case read_file(path) do
      :missing ->
        defaults()

      {:ok, ""} ->
        defaults()

      {:ok, contents} ->
        parse(contents)

      {:error, _reason} ->
        defaults()
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, nil} ->
        defaults()

      {:ok, map} when is_map(map) ->
        build(map)

      {:ok, _other} ->
        diag = %{kind: :parse_error, message: "root of .spec/config.yml must be a mapping"}
        %__MODULE__{defaults() | diagnostics: [diag]}

      {:error, error} ->
        diag = %{kind: :parse_error, message: Exception.message(error)}
        %__MODULE__{defaults() | diagnostics: [diag]}
    end
  end

  defp build(map) do
    test_tags_map = Map.get(map, "test_tags", %{}) || %{}

    %__MODULE__{
      test_tags: build_test_tags(test_tags_map)
    }
  end

  defp build_test_tags(map) when is_map(map) do
    default = %TestTags{}

    %TestTags{
      enabled: parse_enabled(map, default.enabled),
      paths: parse_paths(map, default.paths),
      enforcement: parse_enforcement(map, default.enforcement)
    }
  end

  defp build_test_tags(_), do: %TestTags{}

  defp parse_enabled(map, default) do
    case Map.get(map, "enabled") do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp parse_paths(map, default) do
    case Map.get(map, "paths") do
      list when is_list(list) ->
        strings = Enum.filter(list, &is_binary/1)
        if strings == [], do: default, else: strings

      _ ->
        default
    end
  end

  defp parse_enforcement(map, default) do
    case Map.get(map, "enforcement") do
      nil ->
        default

      "warning" ->
        :warning

      "error" ->
        :error

      :warning ->
        :warning

      :error ->
        :error

      other ->
        Logger.warning(
          "Unknown .spec/config.yml test_tags.enforcement value: #{inspect(other)}. Using :#{default}."
        )

        default
    end
  end
end
