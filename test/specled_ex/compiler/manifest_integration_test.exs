Code.require_file("../../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule SpecLedEx.Compiler.ManifestIntegrationTest do
  use SpecLedEx.IntegrationCase
  @moduletag spec: ["specled.compiler_context.manifest_fixture_integration"]

  alias SpecLedEx.Compiler.{Context, Manifest}

  setup_all do
    {_root, build_path} = compile_fixture("sample_project")
    {:ok, build_path: build_path}
  end

  describe "Manifest.load/1 against test/fixtures/sample_project/" do
    @tag :integration
    test "returns a map with at least one module entry with non-empty sources", %{
      build_path: build_path
    } do
      manifest_file = manifest_path(build_path, :test, :sample_project)
      manifest = Manifest.load(manifest_file)

      assert is_map(manifest), "expected a map, got: #{inspect(manifest)}"

      # Find any module entry whose sources list is non-empty (Sample should qualify)
      non_empty =
        manifest
        |> Enum.find(fn {_mod, _tuple} ->
          case Manifest.sources_for(manifest, Sample) do
            [_ | _] -> true
            _ -> false
          end
        end)

      # Either Sample specifically, or any module with sources — both satisfy
      has_any_with_sources =
        Enum.any?(manifest, fn {mod, _} ->
          match?([_ | _], Manifest.sources_for(manifest, mod))
        end)

      assert non_empty != nil or has_any_with_sources,
             "manifest has no module with a non-empty sources list: #{inspect(manifest, limit: 3)}"
    end

    @tag :integration
    test "Context.load/1 populates manifest from the fixture build path", %{build_path: build_path} do
      context =
        Context.load(
          app: :sample_project,
          env: :test,
          build_path: build_path
        )

      assert %Context{} = context
      assert is_map(context.manifest)
      assert context.compile_path != nil
    end
  end
end
