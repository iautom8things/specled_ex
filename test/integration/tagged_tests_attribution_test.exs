Code.require_file("../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule SpecLedEx.Integration.TaggedTestsAttributionTest do
  # IntegrationCase scaffolds and runs a real child Mix project.
  use SpecLedEx.IntegrationCase, async: false

  @moduletag spec: ["specled.tagged_tests.formatter_streams_jsonl"]

  alias SpecLedEx.TaggedTests

  describe "formatter_streams_jsonl (end to end)" do
    @tag :integration
    test "a real mix test run with the formatter flags writes a per-test evidence artifact" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      artifact =
        Path.join(System.tmp_dir!(), "attr_it_#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm_rf!(artifact) end)

      {output, status} = run_with_formatter(root, artifact)

      assert status == 0,
             "expected the fixture mix test run to pass, got #{status}.\nOutput:\n#{output}"

      assert File.exists?(artifact),
             "expected the streaming artifact at #{artifact}.\nOutput:\n#{output}"

      events =
        artifact
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      by_event = Enum.group_by(events, & &1["event"])

      assert [started] = by_event["test_started"]
      assert started["spec"] == ["req.demo"]
      assert started["file"] =~ "spec_tagged_test.exs"

      assert [finished] = by_event["test_finished"]
      assert finished["state"] == "pass"
      assert finished["spec"] == ["req.demo"]

      assert [_suite] = by_event["suite_finished"]

      # An untagged sibling test in the same file must not be recorded.
      assert length(events) == 3
    end
  end

  # Runs `mix test` with both attribution formatter flags and the artifact env
  # var set, mirroring the merged command the verifier builds. `mix test`'s
  # loadpaths purges ERL_LIBS-added paths, so the fixture's test_helper re-adds
  # the parent app ebins (spec_led_ex + its deps, incl. Jason) via
  # SPECLED_EX_LIB before ExUnit boots the formatter.
  defp run_with_formatter(root, artifact) do
    parent_lib = Path.expand("_build/#{Mix.env()}/lib")

    args =
      ["test"] ++
        String.split(TaggedTests.include_integration_flag()) ++ TaggedTests.formatter_flags()

    System.cmd("mix", args,
      cd: root,
      env: [
        {"MIX_ENV", "test"},
        {"ERL_LIBS", parent_lib},
        {"SPECLED_EX_LIB", parent_lib},
        {"SPECLED_ATTRIBUTION_PATH", artifact}
      ],
      stderr_to_stdout: true
    )
  end

  defp scaffold_fixture do
    base =
      System.tmp_dir!()
      |> Path.join("specled_attr_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "test", "test_helper.exs"]), test_helper())
    File.write!(Path.join([base, "test", "spec_tagged_test.exs"]), spec_tagged_test_module())

    base
  end

  defp mix_exs do
    """
    defmodule SpecledAttrFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :specled_attr_fixture,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end

      def application, do: []
    end
    """
  end

  # `mix test` loadpaths purges ERL_LIBS entries, so re-prepend every parent app
  # ebin (spec_led_ex and its deps, including Jason) here — this runs after
  # loadpaths and before ExUnit boots the streaming formatter.
  defp test_helper do
    """
    case System.get_env("SPECLED_EX_LIB") do
      nil ->
        :ok

      lib ->
        for ebin <- Path.wildcard(Path.join(lib, "*/ebin")) do
          Code.prepend_path(String.to_charlist(ebin))
        end
    end

    ExUnit.start()
    """
  end

  defp spec_tagged_test_module do
    """
    defmodule SpecTaggedTest do
      use ExUnit.Case, async: false

      @tag spec: "req.demo"
      test "spec-tagged test passes" do
        assert 1 + 1 == 2
      end

      test "untagged sibling is not attributed" do
        assert true
      end
    end
    """
  end
end
