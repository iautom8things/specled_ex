defmodule SpecLedEx.Compiler.ManifestTest do
  use ExUnit.Case, async: true

  @moduletag spec: [
               "specled.compiler_context.load_from_opts",
               "specled.compiler_context.manifest_wraps_stdlib",
               "specled.compiler_context.struct_shape"
             ]

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
        MyApp.Foo => {:module, :elixir, ["lib/my_app/foo.ex"], :other, :more, :extras, :last}
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

  describe "Context.load/1 — default manifest path (specled.compiler_context.default_manifest_path)" do
    @tag spec: "specled.compiler_context.default_manifest_path"
    test "derives the manifest as the sibling .mix/compile.elixir of the app dir" do
      tmp = Path.join(System.tmp_dir!(), "ctx_default_#{:erlang.unique_integer([:positive])}")
      app_dir = Path.join([tmp, "_build", "test", "lib", "myapp"])
      File.mkdir_p!(Path.join(app_dir, "ebin"))
      File.mkdir_p!(Path.join(app_dir, ".mix"))

      # A real manifest, so a wrong default path is distinguishable from a
      # format problem: the test VM's own compile manifest.
      File.cp!(
        Path.join(Mix.Project.manifest_path(), "compile.elixir"),
        Path.join([app_dir, ".mix", "compile.elixir"])
      )

      context = Context.load(app: :myapp, env: :test, build_path: Path.join(tmp, "_build"))

      assert map_size(context.manifest) > 0,
             "default derivation loaded 0 modules — likely resolving under ebin/"

      assert Map.has_key?(context.manifest, SpecLedEx.Compiler.Context)

      File.rm_rf!(tmp)
    end

    @tag spec: "specled.compiler_context.default_manifest_path"
    test "an explicit compile_path override still resolves its own sibling .mix/" do
      tmp = Path.join(System.tmp_dir!(), "ctx_sibling_#{:erlang.unique_integer([:positive])}")
      app_dir = Path.join([tmp, "elsewhere", "custom_app"])
      File.mkdir_p!(Path.join(app_dir, "ebin"))
      File.mkdir_p!(Path.join(app_dir, ".mix"))

      File.cp!(
        Path.join(Mix.Project.manifest_path(), "compile.elixir"),
        Path.join([app_dir, ".mix", "compile.elixir"])
      )

      context =
        Context.load(
          app: :irrelevant,
          env: :test,
          build_path: Path.join(tmp, "_build_that_does_not_exist"),
          compile_path: Path.join(app_dir, "ebin")
        )

      assert map_size(context.manifest) > 0

      File.rm_rf!(tmp)
    end
  end

  describe "Context.from_mix_project/1 (specled.compiler_context.from_mix_project)" do
    @tag spec: "specled.compiler_context.from_mix_project"
    test "yields a non-empty manifest and existing compile_path for the current project" do
      context = Context.from_mix_project()

      assert %Context{} = context

      assert map_size(context.manifest) > 0,
             "expected the test VM's own compile manifest to load non-empty"

      assert Map.has_key?(context.manifest, SpecLedEx.Parser)
      assert File.dir?(context.compile_path)
    end

    @tag spec: "specled.compiler_context.from_mix_project"
    test "keyword overrides win over derived values" do
      context = Context.from_mix_project(manifest_path: "/nonexistent/compile.elixir")

      assert context.manifest == %{}
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
