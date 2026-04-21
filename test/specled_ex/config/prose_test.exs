defmodule SpecLedEx.Config.ProseTest do
  use SpecLedEx.Case

  @moduletag :capture_log

  alias SpecLedEx.Config
  alias SpecLedEx.Config.Prose

  describe "defaults/0" do
    @tag spec: "specled.prose_guard.config_thresholds"
    test "returns min_chars=40, min_words=6" do
      assert %Prose{min_chars: 40, min_words: 6} = Prose.defaults()
    end
  end

  describe "parse/1" do
    @tag spec: "specled.prose_guard.config_thresholds"
    test "accepts integers for both fields with no diagnostics" do
      assert {%Prose{min_chars: 80, min_words: 12}, []} =
               Prose.parse(%{"min_chars" => 80, "min_words" => 12})
    end

    @tag spec: "specled.prose_guard.config_thresholds"
    test "missing keys fall back to defaults without diagnostics" do
      assert {%Prose{min_chars: 40, min_words: 6}, []} = Prose.parse(%{})
    end

    @tag spec: "specled.prose_guard.config_thresholds"
    test "rejects negative integers with a diagnostic" do
      {%Prose{min_chars: 40}, diagnostics} = Prose.parse(%{"min_chars" => -1})
      assert Enum.any?(diagnostics, &String.contains?(&1, "min_chars"))
      assert Enum.any?(diagnostics, &String.contains?(&1, "-1"))
    end

    @tag spec: "specled.prose_guard.config_thresholds"
    test "rejects non-integer values with a diagnostic" do
      {%Prose{min_words: 6}, diagnostics} = Prose.parse(%{"min_words" => "lots"})
      assert Enum.any?(diagnostics, &String.contains?(&1, "min_words"))
    end
  end

  describe "schema/0" do
    @tag spec: "specled.prose_guard.config_thresholds"
    test "rejects negative values" do
      assert {:error, _} = Zoi.parse(Prose.schema(), %{min_chars: -1})
    end

    @tag spec: "specled.prose_guard.config_thresholds"
    test "rejects non-integers" do
      assert {:error, _} = Zoi.parse(Prose.schema(), %{min_chars: "lots"})
    end

    @tag spec: "specled.prose_guard.config_thresholds"
    test "accepts non-negative integers" do
      assert {:ok, _} = Zoi.parse(Prose.schema(), %{min_chars: 40, min_words: 6})
    end
  end

  describe "Config.load/2 integrates Prose" do
    @tag spec: "specled.prose_guard.config_thresholds"
    test "loads explicit prose thresholds from YAML", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join([root, ".spec", "config.yml"]), """
      prose:
        min_chars: 80
        min_words: 10
      """)

      config = Config.load(root)
      assert config.prose == %Prose{min_chars: 80, min_words: 10}
      assert config.diagnostics == []
    end

    @tag spec: "specled.prose_guard.config_thresholds"
    test "records a diagnostic when a value is negative", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join([root, ".spec", "config.yml"]), """
      prose:
        min_chars: -5
      """)

      config = Config.load(root)
      assert config.prose.min_chars == 40
      assert Enum.any?(config.diagnostics, &(&1.message =~ "min_chars"))
    end
  end

  describe "findings/3 unit" do
    @tag spec: "specled.prose_guard.finding_emitted"
    test "emits one finding for a too-short must statement" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{"id" => "x.subject"},
            "requirements" => [
              %{
                "id" => "x.short",
                "priority" => "must",
                "statement" => "Does the thing."
              }
            ]
          }
        ]
      }

      [finding] = Prose.findings(index, Prose.defaults(), %{})
      assert finding["code"] == "spec_requirement_too_short"
      assert finding["subject_id"] == "x.subject"
      assert finding["message"] =~ "x.short"
      assert finding["message"] =~ "chars"
      assert finding["severity"] == "info"
    end

    @tag spec: "specled.prose_guard.non_must_exempt"
    test "does not flag should-priority requirements" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{"id" => "x.subject"},
            "requirements" => [
              %{"id" => "x.optional", "priority" => "should", "statement" => "Does it."}
            ]
          }
        ]
      }

      assert Prose.findings(index, Prose.defaults(), %{}) == []
    end

    @tag spec: "specled.prose_guard.severity_configurable"
    test "severities :off suppresses findings" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{"id" => "x.subject"},
            "requirements" => [
              %{"id" => "x.short", "priority" => "must", "statement" => "Does it."}
            ]
          }
        ]
      }

      assert Prose.findings(index, Prose.defaults(), %{
               "spec_requirement_too_short" => :off
             }) == []
    end

    @tag spec: "specled.prose_guard.severity_configurable"
    test "severities :error escalates the finding" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{"id" => "x.subject"},
            "requirements" => [
              %{"id" => "x.short", "priority" => "must", "statement" => "Does it."}
            ]
          }
        ]
      }

      [finding] =
        Prose.findings(index, Prose.defaults(), %{"spec_requirement_too_short" => :error})

      assert finding["severity"] == "error"
    end

    @tag spec: "specled.prose_guard.finding_emitted"
    test "word-only dimension failure is labeled words" do
      # 60 chars but only 5 words → passes char threshold, fails word threshold
      long_short = "Thingamabob whatchamacallit supercalifragilisticexpialidocious noob boop"
      assert String.length(long_short) >= 40

      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{"id" => "x.subject"},
            "requirements" => [
              %{"id" => "x.r", "priority" => "must", "statement" => long_short}
            ]
          }
        ]
      }

      [finding] = Prose.findings(index, Prose.defaults(), %{})
      assert finding["message"] =~ "words"
      refute finding["message"] =~ "chars"
    end

    @tag spec: "specled.prose_guard.finding_emitted"
    test "adequately long statements produce no finding" do
      long =
        "This requirement statement is deliberately written long enough " <>
          "to clear both the character count and the word count thresholds."

      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{"id" => "x.subject"},
            "requirements" => [
              %{"id" => "x.ok", "priority" => "must", "statement" => long}
            ]
          }
        ]
      }

      assert Prose.findings(index, Prose.defaults(), %{}) == []
    end
  end

  describe "mix spec.validate integration" do
    @tag spec: "specled.prose_guard.finding_emitted"
    test "reports a too-short must finding in the state file (too_short_must_flagged)",
         %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      init_git_repo(root)

      write_subject_spec(
        root,
        "x",
        meta: %{"id" => "x.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "x.short", "priority" => "must", "statement" => "Does the thing."}
        ]
      )

      Mix.Tasks.Spec.Validate.run(["--root", root])

      state = read_state(root)
      findings = state["findings"] || []

      assert Enum.any?(findings, fn f ->
               f["code"] == "spec_requirement_too_short" and
                 (f["subject_id"] == "x.subject" or f["message"] =~ "x.short")
             end)
    end

    @tag spec: "specled.prose_guard.severity_configurable"
    test "config severity :off suppresses the finding in the state file", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      init_git_repo(root)

      File.write!(Path.join([root, ".spec", "config.yml"]), """
      branch_guard:
        severities:
          spec_requirement_too_short: off
      """)

      write_subject_spec(
        root,
        "x",
        meta: %{"id" => "x.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "x.short", "priority" => "must", "statement" => "Does the thing."}
        ]
      )

      Mix.Tasks.Spec.Validate.run(["--root", root])

      state = read_state(root)
      findings = state["findings"] || []

      refute Enum.any?(findings, &(&1["code"] == "spec_requirement_too_short"))
    end

    @tag spec: "specled.prose_guard.non_must_exempt"
    test "should-priority requirements are not flagged", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))
      init_git_repo(root)

      write_subject_spec(
        root,
        "x",
        meta: %{"id" => "x.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{"id" => "x.opt", "priority" => "should", "statement" => "Does it."}
        ]
      )

      Mix.Tasks.Spec.Validate.run(["--root", root])

      state = read_state(root)
      findings = state["findings"] || []

      refute Enum.any?(findings, &(&1["code"] == "spec_requirement_too_short"))
    end
  end
end
