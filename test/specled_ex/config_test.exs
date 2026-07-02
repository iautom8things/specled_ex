defmodule SpecLedEx.ConfigTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.config.defaults_when_missing",
               "specled.config.guardrails_severities",
               "specled.config.init_scaffolds_config_yml",
               "specled.config.malformed_yaml_degrades",
               "specled.config.paths_filtered_to_strings",
               "specled.config.realization_enabled_tiers",
               "specled.config.unknown_enforcement_warns",
               "specled.config.yaml_parses_known_fields"
             ]

  alias SpecLedEx.Config
  alias SpecLedEx.Config.Realization
  alias SpecLedEx.Config.TestTags
  alias SpecLedEx.Config.Verification

  import ExUnit.CaptureLog

  describe "defaults/0" do
    @tag spec: "specled.config.defaults_when_missing"
    test "returns a config with no diagnostics and sane test_tags defaults" do
      config = Config.defaults()

      assert %Config{
               test_tags: %TestTags{enabled: false, paths: ["test"], enforcement: :warning},
               realization: %Realization{enabled_tiers: nil, rejected: []},
               verification: %Verification{command_timeout_ms: nil},
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
      verification:
        command_timeout_ms: 600000
        severities:
          requirement_without_verification: info
      """)

      assert %Config{
               test_tags: %TestTags{
                 enabled: true,
                 paths: ["test/specled_ex"],
                 enforcement: :error
               },
               verification: %Verification{
                 command_timeout_ms: 600_000,
                 severities: %{"requirement_without_verification" => :info}
               },
               diagnostics: []
             } = Config.load(root)
    end

    @tag spec: "specled.config.yaml_parses_known_fields"
    test "invalid command_timeout_ms falls back to the verifier default", %{root: root} do
      write_config(root, """
      verification:
        command_timeout_ms: never
      """)

      config = Config.load(root)

      assert config.verification.command_timeout_ms == nil

      assert [
               %{
                 kind: :config_warning,
                 message: "verification.command_timeout_ms must be a positive integer" <> _
               }
             ] = config.diagnostics
    end

    @tag spec: "specled.config.yaml_parses_known_fields"
    test "invalid verification severity entries are dropped with diagnostics", %{root: root} do
      write_config(root, """
      verification:
        severities:
          requirement_without_verification: panic
      """)

      config = Config.load(root)

      assert config.verification.severities == %{}

      assert [
               %{
                 kind: :config_warning,
                 message:
                   "verification.severities.requirement_without_verification must be one of" <> _
               }
             ] = config.diagnostics
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

  describe "load/2 guardrails.severities" do
    @tag spec: "specled.config.guardrails_severities"
    test "parses known severity tokens keyed by finding code", %{root: root} do
      write_config(root, """
      guardrails:
        severities:
          append_only/requirement_deleted: warning
          overlap/duplicate_covers: off
      """)

      config = Config.load(root)

      assert config.guardrails.severities == %{
               "append_only/requirement_deleted" => :warning,
               "overlap/duplicate_covers" => :off
             }

      assert config.branch_guard.severities == %{}
      assert config.diagnostics == []
    end

    @tag spec: "specled.config.guardrails_severities"
    test "drops unknown severity tokens and records a config_warning diagnostic", %{root: root} do
      write_config(root, """
      guardrails:
        severities:
          overlap/duplicate_covers: panic
      """)

      config = Config.load(root)

      assert config.guardrails.severities == %{}

      assert Enum.any?(config.diagnostics, fn diag ->
               diag.kind == :config_warning and
                 diag.message =~ "overlap/duplicate_covers" and
                 diag.message =~ "panic"
             end)
    end

    @tag spec: "specled.config.guardrails_severities"
    test "guardrails and branch_guard keep separate namespaces", %{root: root} do
      write_config(root, """
      branch_guard:
        severities:
          branch_guard_unmapped_change: off
      guardrails:
        severities:
          append_only/requirement_deleted: info
      """)

      config = Config.load(root)

      assert config.branch_guard.severities == %{"branch_guard_unmapped_change" => :off}
      assert config.guardrails.severities == %{"append_only/requirement_deleted" => :info}
      assert config.diagnostics == []
    end

    @tag spec: "specled.config.guardrails_severities"
    test "defaults to empty map when `guardrails` key is absent", %{root: root} do
      write_config(root, """
      test_tags:
        enabled: true
      """)

      config = Config.load(root)
      assert config.guardrails.severities == %{}
    end
  end

  describe "load/2 realization.enabled_tiers" do
    @tag spec: "specled.config.realization_enabled_tiers"
    test "parses a realization section into config.realization", %{root: root} do
      write_config(root, """
      realization:
        enabled_tiers:
          - api_boundary
          - implementation
      """)

      assert %Config{
               realization: %Realization{
                 enabled_tiers: [:api_boundary, :implementation],
                 rejected: []
               },
               diagnostics: []
             } = Config.load(root)
    end

    @tag spec: "specled.config.realization_enabled_tiers"
    test "wraps rejected realization tiers as config_warning diagnostics", %{root: root} do
      write_config(root, """
      realization:
        enabled_tiers:
          - api_boundary
          - mystery
      """)

      config = Config.load(root)

      assert config.realization.enabled_tiers == [:api_boundary]
      assert config.realization.rejected == ["mystery"]

      assert [
               %{
                 kind: :config_warning,
                 message: "realization.enabled_tiers rejected: \"mystery\""
               }
             ] = config.diagnostics
    end

    @tag spec: "specled.config.realization_enabled_tiers"
    test "uses realization defaults when the section is missing", %{root: root} do
      write_config(root, """
      test_tags:
        enabled: true
      """)

      config = Config.load(root)

      assert config.realization == Realization.defaults()
      assert config.realization.enabled_tiers == nil
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
