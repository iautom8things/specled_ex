defmodule SpecLedEx.TaggedTests.Attribution do
  @moduledoc """
  Reads the streaming evidence artifact written by
  `SpecLedEx.TaggedTests.Formatter` and classifies each merged-run cover id by
  the runtime outcome observed for its `@tag spec:` tests.

  `read_artifact/1` returns `:absent` only when the artifact file is missing or
  unreadable — the signal that the formatter transport never engaged (old host,
  rejected formatter flag, error before ExUnit loaded). An existing file is
  reported as `{:ok, events}` even when it holds zero parseable events, so a
  timeout that killed the run before the first test still carries positive
  evidence that the transport was live (a compile-cost timeout) rather than
  degrading silently. See `specled.decision.evidence_based_attribution`.
  """

  @type test_id :: String.t()
  @type outcome ::
          :passed
          | {:failed, [test_id()]}
          | {:in_flight, [test_id()]}
          | :not_started
          | :not_executed

  @spec read_artifact(String.t()) :: {:ok, [map()]} | :absent
  def read_artifact(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse_events(content)}
      {:error, _} -> :absent
    end
  end

  def read_artifact(_), do: :absent

  @spec suite_finished?([map()]) :: boolean()
  def suite_finished?(events) when is_list(events) do
    Enum.any?(events, &(Map.get(&1, "event") == "suite_finished"))
  end

  @doc """
  Classifies each cover id by the runtime outcome recorded in `events`.

  A cover id is matched to an event when the event's `spec` list contains the
  cover id OR when the event's `{file, line}` is listed in `cover_locations`
  for that cover id. The location fallback exists because ExUnit collapses a
  test's multiple `@tag spec:` declarations (and any `@moduletag spec:` list)
  down to a single effective tag at runtime, so a cover declared only via a
  shadowed tag never appears in the recorded `spec` list even though its test
  actually ran. The tag scanner knows where that test lives, so the caller
  passes `cover_locations` (cover id -> `[{file, line}]`) to credit it by
  location. See `specled.decision.evidence_based_attribution`.
  """
  @spec attribute([map()], [String.t()], %{optional(String.t()) => [{String.t(), integer()}]}) ::
          %{optional(String.t()) => outcome()}
  def attribute(events, cover_ids, cover_locations \\ %{})
      when is_list(events) and is_list(cover_ids) and is_map(cover_locations) do
    suite_finished? = suite_finished?(events)

    Map.new(cover_ids, fn cover_id ->
      locations = Map.get(cover_locations, cover_id, [])
      {cover_id, classify(cover_id, events, suite_finished?, locations)}
    end)
  end

  defp parse_events(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end
    end)
  end

  defp classify(cover_id, events, suite_finished?, locations) do
    location_set = MapSet.new(locations)

    cover_events =
      Enum.filter(events, fn event ->
        cover_id in spec_of(event) or MapSet.member?(location_set, event_location(event))
      end)

    finished = Enum.filter(cover_events, &(Map.get(&1, "event") == "test_finished"))
    started = Enum.filter(cover_events, &(Map.get(&1, "event") == "test_started"))

    failed = Enum.filter(finished, &(Map.get(&1, "state") in ["failed", "invalid"]))
    passed = Enum.filter(finished, &(Map.get(&1, "state") == "pass"))
    finished_ids = MapSet.new(finished, &Map.get(&1, "id"))
    in_flight = Enum.reject(started, &MapSet.member?(finished_ids, Map.get(&1, "id")))

    cond do
      failed != [] -> {:failed, descriptors(failed)}
      passed != [] -> :passed
      in_flight != [] -> {:in_flight, descriptors(in_flight)}
      suite_finished? -> :not_executed
      true -> :not_started
    end
  end

  defp spec_of(event) do
    case Map.get(event, "spec") do
      list when is_list(list) -> list
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp event_location(event), do: {Map.get(event, "file"), Map.get(event, "line")}

  defp descriptors(events) do
    events
    |> Enum.map(&descriptor/1)
    |> Enum.uniq()
  end

  defp descriptor(event) do
    file = Map.get(event, "file")
    line = Map.get(event, "line")

    cond do
      is_binary(file) and is_integer(line) -> "#{file}:#{line}"
      is_binary(file) -> file
      true -> Map.get(event, "id") || "unknown test"
    end
  end
end
