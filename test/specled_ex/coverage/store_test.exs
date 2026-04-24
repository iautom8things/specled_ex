defmodule SpecLedEx.Coverage.StoreTest do
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.coverage_capture.artifact_path", "specled.coverage_capture.store_split"]

  alias SpecLedEx.Coverage.Store

  describe "default_path/0" do
    test "matches the spec-mandated artifact location" do
      assert Store.default_path() == ".spec/_coverage/per_test.coverdata"
    end
  end

  describe "build_records/1" do
    test "normalizes loosely-typed maps into records with the five required fields" do
      pid = self()

      input = [
        %{
          test_id: "ATest.test a",
          file: "lib/a.ex",
          lines_hit: [1, 2],
          tags: %{file: "test/a_test.exs"},
          test_pid: pid,
          extra: "dropped"
        }
      ]

      [record] = Store.build_records(input)

      assert record == %{
               test_id: "ATest.test a",
               file: "lib/a.ex",
               lines_hit: [1, 2],
               tags: %{file: "test/a_test.exs"},
               test_pid: pid
             }
    end

    test "preserves order across many entries" do
      pid = self()
      input = for n <- 1..5, do: record(n, pid)
      assert Enum.map(Store.build_records(input), & &1.test_id) ==
               Enum.map(input, & &1.test_id)
    end

    test "raises KeyError when a required field is missing" do
      bad = [%{test_id: "x", file: "y.ex", lines_hit: [1], tags: %{}}]
      assert_raise KeyError, fn -> Store.build_records(bad) end
    end
  end

  describe "store_round_trip scenario" do
    test "write then read returns input records byte-equal, order preserved" do
      tmp_path = Path.join(System.tmp_dir!(), "store_rt_#{System.unique_integer([:positive])}.coverdata")
      on_exit(fn -> File.rm_rf!(tmp_path) end)

      pid = self()

      records =
        Store.build_records([
          record(1, pid),
          record(2, pid),
          record(3, pid)
        ])

      assert :ok = Store.write(records, tmp_path)
      assert File.exists?(tmp_path)

      decoded = Store.read(tmp_path)

      assert decoded == records
      assert :erlang.term_to_binary(decoded) == :erlang.term_to_binary(records)
    end

    test "write creates the parent directory if missing" do
      tmp_dir = Path.join(System.tmp_dir!(), "store_mkdir_#{System.unique_integer([:positive])}")
      tmp_path = Path.join([tmp_dir, "nested", "per_test.coverdata"])
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      records = Store.build_records([record(1, self())])
      assert :ok = Store.write(records, tmp_path)
      assert File.exists?(tmp_path)
    end
  end

  defp record(n, pid) do
    %{
      test_id: "M.t#{n}",
      file: "lib/m#{n}.ex",
      lines_hit: [n, n + 1],
      tags: %{n: n},
      test_pid: pid
    }
  end
end
