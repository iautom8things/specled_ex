defmodule SpecLedEx.TaggedTests.FormatterTest do
  # async: false — the noop test mutates the process-global
  # SPECLED_ATTRIBUTION_PATH env var to exercise the unset path.
  use ExUnit.Case, async: false

  @moduletag spec: [
               "specled.tagged_tests.formatter_streams_jsonl",
               "specled.tagged_tests.formatter_noop_without_artifact_path"
             ]

  alias SpecLedEx.TaggedTests.Formatter

  defp tmp_artifact do
    path =
      Path.join(System.tmp_dir!(), "fmt_stream_#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp test_struct(opts) do
    %ExUnit.Test{
      module: Keyword.get(opts, :module, SomeTest),
      name: Keyword.get(opts, :name, :"test does a thing"),
      state: Keyword.get(opts, :state),
      tags: Keyword.get(opts, :tags, %{})
    }
  end

  describe "formatter_streams_jsonl" do
    @tag spec: "specled.tagged_tests.formatter_streams_jsonl"
    test "emits one line-flushed JSONL event per spec-tagged lifecycle cast" do
      path = tmp_artifact()
      {:ok, state} = Formatter.init(artifact_path: path)

      test = test_struct(tags: %{spec: "req.alpha", file: "test/alpha_test.exs", line: 12})

      {:noreply, ^state} = Formatter.handle_cast({:test_started, test}, state)

      # Line-flushed: the started line is on disk before the suite ends.
      assert [started] = lines(path)
      assert started["event"] == "test_started"

      finished = %{test | state: nil}
      {:noreply, ^state} = Formatter.handle_cast({:test_finished, finished}, state)
      {:noreply, ^state} = Formatter.handle_cast({:suite_finished, %{}}, state)

      assert [started, finished_ev, suite] = lines(path)

      assert started == %{
               "event" => "test_started",
               "id" => "SomeTest.test does a thing",
               "file" => "test/alpha_test.exs",
               "line" => 12,
               "spec" => ["req.alpha"]
             }

      assert finished_ev["event"] == "test_finished"
      assert finished_ev["state"] == "pass"
      assert finished_ev["spec"] == ["req.alpha"]
      assert suite == %{"event" => "suite_finished"}
    end

    @tag spec: "specled.tagged_tests.formatter_streams_jsonl"
    test "normalizes a list-valued spec tag to a list and records finished state" do
      path = tmp_artifact()
      {:ok, state} = Formatter.init(artifact_path: path)

      test =
        test_struct(
          name: :"test list tagged",
          state: {:failed, [{:error, %RuntimeError{}, []}]},
          tags: %{spec: ["req.alpha", "req.beta"], file: "test/x_test.exs", line: 4}
        )

      {:noreply, ^state} = Formatter.handle_cast({:test_finished, test}, state)

      assert [event] = lines(path)
      assert event["spec"] == ["req.alpha", "req.beta"]
      assert event["state"] == "failed"
    end

    @tag spec: "specled.tagged_tests.formatter_streams_jsonl"
    test "records only spec-tagged tests, never untagged ones sharing a file" do
      path = tmp_artifact()
      {:ok, state} = Formatter.init(artifact_path: path)

      untagged = test_struct(name: :"test untagged", tags: %{file: "test/x_test.exs", line: 9})
      {:noreply, ^state} = Formatter.handle_cast({:test_started, untagged}, state)
      {:noreply, ^state} = Formatter.handle_cast({:test_finished, untagged}, state)

      refute File.exists?(path)
    end

    @tag spec: "specled.tagged_tests.formatter_streams_jsonl"
    test "maps every ExUnit test state to a stable token" do
      path = tmp_artifact()
      {:ok, state} = Formatter.init(artifact_path: path)

      states = [
        {nil, "pass"},
        {{:failed, []}, "failed"},
        {{:invalid, __MODULE__}, "invalid"},
        {{:skipped, "reason"}, "skipped"},
        {{:excluded, "reason"}, "excluded"}
      ]

      for {raw, _expected} <- states do
        test = test_struct(name: :"test s", state: raw, tags: %{spec: "req.alpha"})
        {:noreply, ^state} = Formatter.handle_cast({:test_finished, test}, state)
      end

      recorded = Enum.map(lines(path), & &1["state"])
      assert recorded == Enum.map(states, &elem(&1, 1))
    end
  end

  describe "formatter_noop_without_artifact_path" do
    @tag spec: "specled.tagged_tests.formatter_noop_without_artifact_path"
    test "init returns :disabled and every handler no-ops when no path is set" do
      original = System.get_env("SPECLED_ATTRIBUTION_PATH")
      System.delete_env("SPECLED_ATTRIBUTION_PATH")
      on_exit(fn -> if original, do: System.put_env("SPECLED_ATTRIBUTION_PATH", original) end)

      assert {:ok, :disabled} = Formatter.init([])
      assert {:ok, :disabled} = Formatter.init(artifact_path: "")

      test = test_struct(tags: %{spec: "req.alpha", file: "test/x_test.exs", line: 1})

      assert {:noreply, :disabled} =
               Formatter.handle_cast({:test_started, test}, :disabled)

      assert {:noreply, :disabled} =
               Formatter.handle_cast({:test_finished, %{test | state: nil}}, :disabled)

      assert {:noreply, :disabled} = Formatter.handle_cast({:suite_finished, %{}}, :disabled)
    end
  end
end
