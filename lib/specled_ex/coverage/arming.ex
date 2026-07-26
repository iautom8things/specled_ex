defmodule SpecLedEx.Coverage.Arming do
  @moduledoc false

  alias SpecLedEx.Coverage
  alias SpecLedEx.Coverage.Snapshot

  @arming_app :specled_ex
  @arming_key :spec_cover_run
  @modules_key :__specled_boundary_modules__

  @type target :: :formatter | :boundary
  @type config :: %{
          snapshot_fn: ([module()] -> Snapshot.module_snapshot()),
          modules_fn: (-> [module()]),
          artifact_path: Path.t(),
          boundary_table: :ets.tid() | nil
        }

  @spec resolve(target()) :: {:armed, config()} | :disarmed
  def resolve(target) when target in [:formatter, :boundary] do
    Application.get_env(@arming_app, @arming_key)
    |> decode(target)
  end

  @spec modules(config()) :: [module()]
  def modules(%{boundary_table: tid, modules_fn: modules_fn}) do
    case :ets.lookup(tid, @modules_key) do
      [{@modules_key, modules}] ->
        modules

      [] ->
        modules = modules_fn.()
        true = :ets.insert(tid, {@modules_key, modules})
        modules
    end
  end

  @spec boundary_index(config()) :: %{optional({module(), atom()}) => map()}
  def boundary_index(%{boundary_table: tid}) do
    tid
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {@modules_key, _modules}, acc -> acc
      {key, row}, acc when is_tuple(key) and is_map(row) -> Map.put(acc, key, row)
      _, acc -> acc
    end)
  end

  defp decode(true, :formatter), do: {:armed, config([])}
  defp decode(true, :boundary), do: :disarmed

  defp decode(opts, target) when is_list(opts) do
    config = config(opts)

    case target do
      :formatter -> {:armed, config}
      :boundary -> if(config.boundary_table, do: {:armed, config}, else: :disarmed)
    end
  end

  defp decode(_value, _target), do: :disarmed

  defp config(opts) do
    %{
      snapshot_fn: Keyword.get(opts, :snapshot_fn, &default_snapshot_fn/1),
      modules_fn: Keyword.get(opts, :modules_fn, &Coverage.cover_modules_safe/0),
      artifact_path: Keyword.get(opts, :artifact_path, Coverage.default_artifact_path()),
      boundary_table: valid_table(Keyword.get(opts, :boundary_table))
    }
  end

  defp valid_table(tid) do
    if :ets.info(tid) == :undefined, do: nil, else: tid
  rescue
    ArgumentError -> nil
  end

  defp default_snapshot_fn(modules), do: Snapshot.take(Snapshot.runtime_mode(), modules)
end
