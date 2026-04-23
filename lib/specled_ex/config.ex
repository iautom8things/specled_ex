defmodule SpecLedEx.Config do
  @moduledoc false

  require Logger

  alias SpecLedEx.Config.BranchGuard
  alias SpecLedEx.Config.Prose

  defmodule TestTags do
    @moduledoc false
    defstruct enabled: false, paths: ["test"], enforcement: :warning

    @type t :: %__MODULE__{
            enabled: boolean(),
            paths: [String.t()],
            enforcement: :warning | :error
          }
  end

  defmodule Guardrails do
    @moduledoc """
    Config section for append-only / overlap guardrail severities.

    ## YAML shape

        guardrails:
          severities:
            append_only/requirement_deleted: warning
            overlap/duplicate_covers: off

    Each entry is `code => severity` where severity is one of `off`, `info`,
    `warning`, `error` (see `SpecLedEx.BranchCheck.Severity`). The code key
    namespace is the 12 guardrail codes (10 `append_only/*` + 2 `overlap/*`)
    introduced by specled_-fm4. `branch_guard.severities` covers its own
    namespace; the two maps are kept separate (not merged) so the two
    guardrail surfaces stay legible in config.

    Unknown severities are rejected and the entry is dropped with a
    diagnostic, mirroring `SpecLedEx.Config.BranchGuard` exactly.
    """

    @severity_tokens %{
      "off" => :off,
      "info" => :info,
      "warning" => :warning,
      "error" => :error
    }

    @type severity :: :off | :info | :warning | :error
    @type t :: %__MODULE__{severities: %{optional(String.t()) => severity()}}

    defstruct severities: %{}

    @spec defaults() :: t()
    def defaults, do: %__MODULE__{}

    @spec parse(term()) :: {t(), [String.t()]}
    def parse(input) when is_map(input) do
      severities_input =
        case Map.get(input, "severities", Map.get(input, :severities, %{})) do
          map when is_map(map) -> map
          _ -> %{}
        end

      {severities, diagnostics} =
        Enum.reduce(severities_input, {%{}, []}, fn {code, severity_token}, {map, diags} ->
          cond do
            not is_binary(code) ->
              {map, [unknown_code_diag(code) | diags]}

            is_binary(severity_token) and Map.has_key?(@severity_tokens, severity_token) ->
              {Map.put(map, code, Map.fetch!(@severity_tokens, severity_token)), diags}

            severity_token in [:off, :info, :warning, :error] ->
              {Map.put(map, code, severity_token), diags}

            true ->
              {map, [unknown_severity_diag(code, severity_token) | diags]}
          end
        end)

      {%__MODULE__{severities: severities}, Enum.reverse(diagnostics)}
    end

    def parse(_), do: {defaults(), []}

    defp unknown_code_diag(code) do
      "guardrails.severities key must be a string finding code, got #{inspect(code)}; dropped"
    end

    defp unknown_severity_diag(code, value) do
      "guardrails.severities.#{code} must be one of off/info/warning/error, got #{inspect(value)}; dropped"
    end
  end

  defstruct test_tags: nil, branch_guard: nil, guardrails: nil, prose: nil, diagnostics: []

  @type diagnostic :: %{kind: atom(), message: String.t()}
  @type t :: %__MODULE__{
          test_tags: TestTags.t(),
          branch_guard: BranchGuard.t(),
          guardrails: Guardrails.t(),
          prose: Prose.t(),
          diagnostics: [diagnostic()]
        }

  @doc "Returns the default configuration with no diagnostics."
  @spec defaults() :: t()
  def defaults do
    %__MODULE__{
      test_tags: %TestTags{},
      branch_guard: BranchGuard.defaults(),
      guardrails: Guardrails.defaults(),
      prose: Prose.defaults()
    }
  end

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
    branch_guard_map = Map.get(map, "branch_guard", %{}) || %{}
    guardrails_map = Map.get(map, "guardrails", %{}) || %{}
    prose_map = Map.get(map, "prose", %{}) || %{}

    {branch_guard, bg_diag} = BranchGuard.parse(branch_guard_map)
    {guardrails, gr_diag} = Guardrails.parse(guardrails_map)
    {prose, prose_diag} = Prose.parse(prose_map)

    diagnostics =
      Enum.map(bg_diag ++ gr_diag ++ prose_diag, fn msg ->
        %{kind: :config_warning, message: msg}
      end)

    %__MODULE__{
      test_tags: build_test_tags(test_tags_map),
      branch_guard: branch_guard,
      guardrails: guardrails,
      prose: prose,
      diagnostics: diagnostics
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
