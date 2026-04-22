defmodule SpecLedEx.Compiler.ManifestTest do
  use ExUnit.Case, async: true

  alias SpecLedEx.Compiler.{Context, Manifest}

  describe "Manifest.load/1" do
    test "returns an empty map when the path does not exist" do
      assert Manifest.load("/tmp/does-not-exist-#{:erlang.unique_integer([:positive])}.manifest") ==
               %{}
    end

    test "returns an empty map for an unreadable path" do
      assert Manifest.load(nil) == %{}
      assert Manifest.load(42) == %{}
    end
  end

  describe "Manifest.sources_for/2" do
    test "returns [] for unknown modules" do
      assert Manifest.sources_for(%{}, SomeModule) == []
    end

    test "pulls the first list-of-binaries field from a manifest tuple" do
      manifest = %{
        MyApp.Foo =>
          {:module, :elixir, ["lib/my_app/foo.ex"], :other, :more, :extras, :last}
      }

      assert Manifest.sources_for(manifest, MyApp.Foo) == ["lib/my_app/foo.ex"]
    end
  end

  describe "Context.load/1 — purely explicit inputs" do
    test "builds a Context without touching Mix globals" do
      tmp = Path.join(System.tmp_dir!(), "ctx_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([tmp, "_build", "test", "lib", "sample_project", "ebin"]))

      context =
        Context.load(
          app: :sample_project,
          env: :test,
          build_path: Path.join(tmp, "_build")
        )

      assert %Context{} = context

      assert context.compile_path ==
               Path.join([tmp, "_build", "test", "lib", "sample_project", "ebin"])

      assert context.manifest == %{}

      File.rm_rf!(tmp)
    end

    test "honors explicit compile_path and manifest_path overrides" do
      tmp = Path.join(System.tmp_dir!(), "ctx_override_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      context =
        Context.load(
          app: :sample_project,
          env: :test,
          build_path: Path.join(tmp, "_build"),
          compile_path: "/custom/ebin",
          manifest_path: "/custom/manifest"
        )

      assert context.compile_path == "/custom/ebin"
      # Manifest at the custom path doesn't exist → empty map
      assert context.manifest == %{}

      File.rm_rf!(tmp)
    end
  end

  describe "orchestrators_take_context (mechanical check)" do
    test "lib/specled_ex/realization/api_boundary.ex has no Mix.env or Mix.Project.config calls" do
      source = File.read!("lib/specled_ex/realization/api_boundary.ex")
      refute source =~ ~r/Mix\.env\b/
      refute source =~ ~r/Mix\.Project\.config\b/
    end

    test "lib/specled_ex/realization/binding.ex has no Mix globals" do
      source = File.read!("lib/specled_ex/realization/binding.ex")
      refute source =~ ~r/Mix\.env\b/
      refute source =~ ~r/Mix\.Project\.config\b/
    end
  end
end
