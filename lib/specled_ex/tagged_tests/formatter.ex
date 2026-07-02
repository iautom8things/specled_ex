defmodule SpecLedEx.TaggedTests.Formatter do
  @moduledoc """
  ExUnit formatter that streams a per-test evidence artifact for merged
  `kind: tagged_tests` runs.

  The formatter appends one line-flushed JSONL event to the path given by the
  `SPECLED_ATTRIBUTION_PATH` env var (an `:artifact_path` init option overrides
  it for unit tests). Only tests carrying a runtime `:spec` tag are recorded, so
  untagged tests sharing a file are never attributed. When no path is
  configured the formatter is disabled and every handler no-ops.

  Each event is a single JSON object: `event`, `id`
  (`"\#{inspect(module)}.\#{name}"`), `file`, `line`, `spec` (always a list),
  and for `test_finished` a `state` in `pass | failed | invalid | skipped |
  excluded`. `suite_finished` emits `{"event":"suite_finished"}`. Writes use
  one `File.write!/3` append per event with no open handle and no
  `:delayed_write`, so a mid-suite SIGKILL loses at most the in-flight line.
  """

  use GenServer

  @impl GenServer
  def init(opts) do
    env_path = System.get_env("SPECLED_ATTRIBUTION_PATH")

    # Consume the env var so nested `mix` subprocesses a test spawns during this
    # run do not inherit it, load a second formatter, and pollute this run's
    # artifact (extra events and a spurious `suite_finished`). A nested run that
    # genuinely wants its own artifact sets the env var explicitly.
    if env_path, do: System.delete_env("SPECLED_ATTRIBUTION_PATH")

    case Keyword.get(opts, :artifact_path, env_path) do
      path when is_binary(path) and path != "" -> {:ok, %{path: path}}
      _ -> {:ok, :disabled}
    end
  end

  @impl GenServer
  def handle_cast(_event, :disabled), do: {:noreply, :disabled}

  def handle_cast({:test_started, %ExUnit.Test{} = test}, %{path: path} = state) do
    write_test_event("test_started", test, path)
    {:noreply, state}
  end

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, %{path: path} = state) do
    write_test_event("test_finished", test, path)
    {:noreply, state}
  end

  def handle_cast({:suite_finished, _times}, %{path: path} = state) do
    write_line(path, %{"event" => "suite_finished"})
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp write_test_event(event, %ExUnit.Test{tags: tags} = test, path) do
    case spec_ids(tags) do
      [] -> :ok
      ids -> write_line(path, test_event_map(event, test, ids))
    end
  end

  defp spec_ids(tags) do
    tags
    |> Map.get(:spec)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp test_event_map(event, %ExUnit.Test{} = test, ids) do
    base = %{
      "event" => event,
      "id" => "#{inspect(test.module)}.#{test.name}",
      "file" => Map.get(test.tags, :file),
      "line" => Map.get(test.tags, :line),
      "spec" => ids
    }

    if event == "test_finished" do
      Map.put(base, "state", test_state(test.state))
    else
      base
    end
  end

  defp test_state(nil), do: "pass"
  defp test_state({:failed, _}), do: "failed"
  defp test_state({:invalid, _}), do: "invalid"
  defp test_state({:skipped, _}), do: "skipped"
  defp test_state({:excluded, _}), do: "excluded"
  defp test_state(_), do: "pass"

  defp write_line(path, map) do
    File.write!(path, Jason.encode!(map) <> "\n", [:append])
  end
end
