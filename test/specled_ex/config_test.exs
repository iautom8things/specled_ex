defmodule SpecLedEx.ConfigTest do
  use SpecLedEx.Case

  alias SpecLedEx.Config
  alias SpecLedEx.Config.TestTags

  import ExUnit.CaptureLog

  describe "defaults/0" do
    @tag spec: "specled.config.defaults_when_missing"
    test "returns a config with no diagnostics and sane test_tags defaults" do
      config = Config.defaults()

      assert %Config{
               test_tags: %TestTags{enabled: false, paths: ["test"], enforcement: :warning},
               diagnostics: []
             } = config
    end
  end

  describe "load/2 without a config file" do
    @tag spec: "specled.config.defaults_when_missing"
    test "returns defaults when .spec/config.yml is missing", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      assert Config.load(root) == Config.defaults()
    end

    @tag spec: "specled.config.defaults_when_missing"
    test "returns defaults when the file is empty", %{root: root} do
      write_config(root, "")
      assert Config.load(root) == Config.defaults()
    end
  end

  describe "load/2 with valid YAML" do
    @tag spec: "specled.config.yaml_parses_known_fields"
    test "parses all known fields", %{root: root} do
      write_config(root, """
      test_tags:
        enabled: true
        paths:
          - test/specled_ex
        enforcement: error
      """)

      assert %Config{
               test_tags: %TestTags{
                 enabled: true,
                 paths: ["test/specled_ex"],
                 enforcement: :error
               },
               diagnostics: []
             } = Config.load(root)
    end

    @tag spec: "specled.config.yaml_parses_known_fields"
    test "missing keys fall back to defaults", %{root: root} do
      write_config(root, """
      test_tags:
        enabled: true
      """)

      assert %Config{test_tags: tt, diagnostics: []} = Config.load(root)
      assert tt.enabled == true
      assert tt.paths == ["test"]
      assert tt.enforcement == :warning
    end
  end

  describe "load/2 with malformed YAML" do
    @tag spec: "specled.config.malformed_yaml_degrades"
    test "returns defaults and records a parse diagnostic", %{root: root} do
      write_config(root, ": not yaml\n  : : :")

      config = Config.load(root)

      assert config.test_tags == Config.defaults().test_tags
      assert [%{kind: :parse_error, message: msg}] = config.diagnostics
      assert is_binary(msg) and msg != ""
    end

    @tag spec: "specled.config.malformed_yaml_degrades"
    test "rejects a scalar root and records a diagnostic", %{root: root} do
      write_config(root, "just-a-scalar")

      config = Config.load(root)

      assert config.test_tags == Config.defaults().test_tags
      assert [%{kind: :parse_error}] = config.diagnostics
    end
  end

  describe "load/2 enforcement parsing" do
    @tag spec: "specled.config.unknown_enforcement_warns"
    test "logs a warning and falls back to default for unknown enforcement values", %{root: root} do
      write_config(root, """
      test_tags:
        enforcement: catastrophic
      """)

      {config, log} =
        with_log(fn -> Config.load(root) end)

      assert config.test_tags.enforcement == :warning
      assert log =~ "catastrophic"
      assert log =~ "enforcement"
    end

    @tag spec: "specled.config.yaml_parses_known_fields"
    test "accepts warning as a string", %{root: root} do
      write_config(root, """
      test_tags:
        enforcement: warning
      """)

      assert Config.load(root).test_tags.enforcement == :warning
    end
  end

  describe "load/2 paths filtering" do
    @tag spec: "specled.config.paths_filtered_to_strings"
    test "filters non-string path entries", %{root: root} do
      write_config(root, """
      test_tags:
        paths:
          - test
          - 42
          - ~
      """)

      assert Config.load(root).test_tags.paths == ["test"]
    end

    @tag spec: "specled.config.paths_filtered_to_strings"
    test "falls back to default paths when the filtered list is empty", %{root: root} do
      write_config(root, """
      test_tags:
        paths:
          - 1
          - 2
      """)

      assert Config.load(root).test_tags.paths == Config.defaults().test_tags.paths
    end
  end

  describe "mix spec.init scaffolds config.yml" do
    @tag spec: "specled.config.init_scaffolds_config_yml"
    test "writes .spec/config.yml that round-trips through load/2", %{root: root} do
      answer_shell_yes(false)

      Mix.Tasks.Spec.Init.run(["--root", root])

      config_path = Path.join(root, ".spec/config.yml")
      assert File.exists?(config_path)
      assert File.read!(config_path) == render_spec_init_template("config.yml.eex")
      assert Config.load(root) == Config.defaults()
    end
  end

  defp write_config(root, body) do
    File.mkdir_p!(Path.join(root, ".spec"))
    File.write!(Path.join([root, ".spec", "config.yml"]), body)
  end
end
