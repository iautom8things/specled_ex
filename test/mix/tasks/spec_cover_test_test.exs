Code.require_file("../../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule Mix.Tasks.Spec.Cover.TestTest do
  use SpecLedEx.IntegrationCase

  alias SpecLedEx.Coverage.Store

  describe "spec_cover_test_forces_serial scenario" do
    @tag :integration
    test "runs serialized, warns about async: true files, writes per_test.coverdata" do
      root = scaffold_async_true_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test"])

      assert status == 0,
             "expected mix spec.cover.test to succeed, got status #{status}.\nOutput:\n#{output}"

      assert output =~ "[spec.cover.test] WARNING",
             "expected async warning header in output. Output was:\n#{output}"

      assert output =~ "test/async_true_test.exs",
             "expected the async-true test file to be named in the warning. Output was:\n#{output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")

      assert File.exists?(artifact),
             "expected #{artifact} to exist. Mix output:\n#{output}"

      records = Store.read(artifact)
      assert is_list(records)
      assert records != [], "expected at least one record per test"

      test_ids = records |> Enum.map(& &1.test_id) |> Enum.uniq()
      assert length(test_ids) >= 2, "expected records for both fixture tests, got: #{inspect(test_ids)}"

      Enum.each(records, fn rec ->
        assert is_binary(rec.test_id)
        assert is_binary(rec.file)
        assert is_list(rec.lines_hit)
        assert is_map(rec.tags)
        assert is_pid(rec.test_pid)
      end)
    end
  end

  defp scaffold_async_true_fixture do
    base =
      System.tmp_dir!()
      |> Path.join("specled_cover_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "lib", "covered.ex"]), lib_module())
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")
    File.write!(Path.join([base, "test", "async_true_test.exs"]), async_true_test_module())
    File.write!(Path.join([base, "test", "default_test.exs"]), default_test_module())

    base
  end

  defp mix_exs do
    """
    defmodule SpecledCoverFixture.MixProject do
      use Mix.Project

      def project do
        ensure_specled_loaded()

        [
          app: :specled_cover_fixture,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end

      def application, do: []

      defp ensure_specled_loaded do
        case System.get_env("SPECLED_EX_EBIN") do
          nil -> :ok
          path -> Code.append_path(String.to_charlist(path))
        end
      end
    end
    """
  end

  defp lib_module do
    """
    defmodule Covered do
      def add(a, b), do: a + b
      def hello, do: :world
    end
    """
  end

  defp async_true_test_module do
    """
    defmodule AsyncTrueTest do
      use ExUnit.Case, async: true

      setup do
        {:ok, test_pid: self()}
      end

      test "covered.add returns sum" do
        assert Covered.add(1, 2) == 3
      end
    end
    """
  end

  defp default_test_module do
    """
    defmodule DefaultTest do
      use ExUnit.Case, async: false

      setup do
        {:ok, test_pid: self()}
      end

      test "covered.hello returns :world" do
        assert Covered.hello() == :world
      end
    end
    """
  end
end
