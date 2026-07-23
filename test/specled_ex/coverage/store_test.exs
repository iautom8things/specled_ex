defmodule SpecLedEx.Coverage.StoreTest do
  use ExUnit.Case, async: true

  @moduletag spec: [
               "specled.coverage_capture.artifact_path",
               "specled.coverage_capture.store_split"
             ]

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
      tmp_path =
        Path.join(System.tmp_dir!(), "store_rt_#{System.unique_integer([:positive])}.coverdata")

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

  describe "build_envelope/1" do
    @describetag spec: ["specled.coverage_capture.store_v2_envelope"]

    test "defaults :version, :generated_at, and :degraded" do
      envelope =
        Store.build_envelope(%{
          mode: :aggregate,
          source: "mix spec.cover.test",
          files: [%{file: "lib/a.ex", lines_hit: [1, 2]}],
          mfas: [%{mfa: "A.f/1", covered: true}],
          payload: nil
        })

      assert envelope.version == 2
      assert envelope.degraded == false
      assert %DateTime{} = envelope.generated_at
    end

    test "raises KeyError when a required field is missing" do
      assert_raise KeyError, fn ->
        Store.build_envelope(%{mode: :aggregate, source: "x", files: [], payload: nil})
      end
    end
  end

  describe "v2 envelope round trip" do
    @describetag spec: [
                   "specled.coverage_capture.store_v2_envelope",
                   "specled.coverage_capture.store_v2_legacy_rejection"
                 ]

    setup do
      tmp_path =
        Path.join(System.tmp_dir!(), "store_v2_#{System.unique_integer([:positive])}.coverdata")

      on_exit(fn ->
        File.rm_rf!(tmp_path)
        File.rm_rf!(Path.join(Path.dirname(tmp_path), "last_run.status"))
      end)

      {:ok, path: tmp_path}
    end

    test "write_v2 -> read_v2 returns an identical envelope", %{path: path} do
      envelope =
        Store.build_envelope(%{
          mode: :aggregate,
          source: "mix spec.cover.test",
          files: [%{file: "lib/a.ex", lines_hit: [1, 2]}],
          mfas: [%{mfa: "A.f/1", covered: true}],
          payload: %{raw: :cover_export}
        })

      assert :ok = Store.write_v2(envelope, path)
      assert {:ok, decoded} = Store.read_v2(path)
      assert decoded == envelope
    end

    test "write_v2 refuses an envelope with empty files", %{path: path} do
      envelope =
        Store.build_envelope(%{
          mode: :aggregate,
          source: "mix spec.cover.test",
          files: [],
          mfas: [],
          payload: nil
        })

      assert {:error, :empty_files} = Store.write_v2(envelope, path)
      refute File.exists?(path)
    end

    test "write_v2 creates the parent directory if missing" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "store_v2_mkdir_#{System.unique_integer([:positive])}")

      tmp_path = Path.join([tmp_dir, "nested", "per_test.coverdata"])
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      envelope =
        Store.build_envelope(%{
          mode: :aggregate,
          source: "mix spec.cover.test",
          files: [%{file: "lib/a.ex", lines_hit: [1]}],
          mfas: [],
          payload: nil
        })

      assert :ok = Store.write_v2(envelope, tmp_path)
      assert File.exists?(tmp_path)
    end

    test "read_v2 on a pre-v2 (legacy) artifact returns :legacy_artifact with a message naming the re-run command",
         %{path: path} do
      legacy_records = Store.build_records([record(1, self())])
      assert :ok = Store.write(legacy_records, path)

      assert {:error, :legacy_artifact, message} = Store.read_v2(path)
      assert message =~ "mix spec.cover.test"
    end

    test "read_v2 on garbage bytes returns :invalid_artifact", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not a valid ETF term")

      assert {:error, :invalid_artifact} = Store.read_v2(path)
    end

    test "read_v2 on a well-formed but non-envelope term returns :invalid_artifact", %{
      path: path
    } do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :erlang.term_to_binary(%{unrelated: "map"}))

      assert {:error, :invalid_artifact} = Store.read_v2(path)
    end

    test "read_v2 on a missing file returns :invalid_artifact", %{path: path} do
      assert {:error, :invalid_artifact} = Store.read_v2(path)
    end
  end

  describe "read_status/1" do
    @describetag spec: ["specled.coverage_capture.store_v2_envelope"]

    setup do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "store_status_#{System.unique_integer([:positive])}.coverdata"
        )

      on_exit(fn ->
        File.rm_rf!(tmp_path)
        File.rm_rf!(Path.join(Path.dirname(tmp_path), "last_run.status"))
      end)

      {:ok, path: tmp_path}
    end

    test "returns {:ok, stats} after a successful write_v2", %{path: path} do
      envelope =
        Store.build_envelope(%{
          mode: :per_test,
          source: "mix spec.cover.test --per-test",
          files: [%{file: "lib/a.ex", lines_hit: [1]}, %{file: "lib/b.ex", lines_hit: [2, 3]}],
          mfas: [%{mfa: "A.f/1", covered: true}],
          payload: nil,
          degraded: true
        })

      assert :ok = Store.write_v2(envelope, path)
      assert {:ok, stats} = Store.read_status(path)
      assert stats.mode == :per_test
      assert stats.file_count == 2
      assert stats.mfa_count == 1
      assert stats.degraded == true
    end

    test "returns {:refused, reason} after a refused write_v2", %{path: path} do
      envelope =
        Store.build_envelope(%{
          mode: :aggregate,
          source: "mix spec.cover.test",
          files: [],
          mfas: [],
          payload: nil
        })

      assert {:error, :empty_files} = Store.write_v2(envelope, path)
      assert {:refused, :empty_files} = Store.read_status(path)
    end

    test "returns {:refused, :not_found} when no sidecar has ever been written", %{path: path} do
      assert {:refused, :not_found} = Store.read_status(path)
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
