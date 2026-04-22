defmodule SpecLedEx.Coverage.Store do
  @moduledoc """
  Reader/writer for the per-test coverage artifact at
  `.spec/_coverage/per_test.coverdata`.

  Records are maps with fields `:test_id`, `:file`, `:lines_hit`, `:tags`, and
  `:test_pid`, encoded as Erlang Term Format (ETF). The schema version is
  implicit; downstream consumers (triangulation) bump their `hasher_version`
  when the layout changes.

  `build_records/1` is a pure helper for tests that need to author artifacts
  without instantiating a formatter or running `:cover`.
  """

  alias SpecLedEx.Coverage

  @type record :: %{
          required(:test_id) => String.t(),
          required(:file) => String.t(),
          required(:lines_hit) => [non_neg_integer()],
          required(:tags) => map(),
          required(:test_pid) => pid()
        }

  @doc """
  On-disk path for the per-test artifact.
  """
  @spec default_path() :: Path.t()
  def default_path, do: Coverage.default_artifact_path()

  @doc """
  Builds a list of normalized per-test records from loosely-typed Elixir
  input. Each input entry must carry the five required fields; extra keys are
  dropped. Order is preserved.
  """
  @spec build_records([map()]) :: [record()]
  def build_records(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        test_id: fetch!(entry, :test_id),
        file: fetch!(entry, :file),
        lines_hit: fetch!(entry, :lines_hit),
        tags: fetch!(entry, :tags),
        test_pid: fetch!(entry, :test_pid)
      }
    end)
  end

  @doc """
  Writes records to `path` as ETF. Creates the parent directory if missing.
  """
  @spec write([record()], Path.t()) :: :ok
  def write(records, path) when is_list(records) and is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(records))
    :ok
  end

  @doc """
  Reads and decodes the ETF artifact at `path`. Returns the record list.
  """
  @spec read(Path.t()) :: [record()]
  def read(path) when is_binary(path) do
    path
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  defp fetch!(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end
end
