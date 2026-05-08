defmodule SpecLedEx.Validator.RealizedByDedupCheckTest do
  use ExUnit.Case, async: true

  @moduletag spec: [
               "specled.realized_by.redundant_dup_warning",
               "specled.realized_by.dedup_check_shared_seam"
             ]

  alias SpecLedEx.Validator.RealizedByDedupCheck
  alias SpecLedEx.Validator.RealizedByDedupe

  describe "RealizedByDedupe.duplicates/1 (shared seam)" do
    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "returns one entry per cross-tier duplicate, sorted, trimmed" do
      subject = %{
        "file" => ".spec/specs/x.spec.md",
        "meta" => %{
          "id" => "x.subject",
          "realized_by" => %{
            "api_boundary" => ["  Mod.b/2  ", "Mod.a/1"],
            "implementation" => ["Mod.a/1", "  Mod.b/2"]
          }
        }
      }

      assert RealizedByDedupe.duplicates(subject) == [
               {{"api_boundary", "implementation"}, "Mod.a/1"},
               {{"api_boundary", "implementation"}, "Mod.b/2"}
             ]
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "returns [] when only one tier carries entries" do
      subject = %{
        "meta" => %{
          "id" => "x.subject",
          "realized_by" => %{
            "implementation" => ["Mod.a/1"]
          }
        }
      }

      assert RealizedByDedupe.duplicates(subject) == []
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "returns [] when entries differ across tiers" do
      subject = %{
        "meta" => %{
          "id" => "x.subject",
          "realized_by" => %{
            "api_boundary" => ["Mod.a/1"],
            "implementation" => ["Mod.b/2"]
          }
        }
      }

      assert RealizedByDedupe.duplicates(subject) == []
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "ignores duplicate occurrences within the same tier (no spurious matches)" do
      subject = %{
        "meta" => %{
          "id" => "x.subject",
          "realized_by" => %{
            # Mod.a/1 is duplicated within api_boundary but absent from
            # implementation — must NOT be reported as a cross-tier dup.
            "api_boundary" => ["Mod.a/1", "Mod.a/1"],
            "implementation" => ["Mod.b/2"]
          }
        }
      }

      assert RealizedByDedupe.duplicates(subject) == []
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "trims entries before intersection (whitespace-only difference still matches)" do
      subject = %{
        "meta" => %{
          "id" => "x.subject",
          "realized_by" => %{
            "api_boundary" => ["  Mod.a/1  "],
            "implementation" => ["Mod.a/1"]
          }
        }
      }

      assert RealizedByDedupe.duplicates(subject) == [
               {{"api_boundary", "implementation"}, "Mod.a/1"}
             ]
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "accepts atom-keyed realized_by under top-level" do
      subject = %{
        :realized_by => %{
          api_boundary: ["Mod.a/1"],
          implementation: ["Mod.a/1"]
        }
      }

      assert RealizedByDedupe.duplicates(subject) == [
               {{"api_boundary", "implementation"}, "Mod.a/1"}
             ]
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "ignores tiers other than api_boundary/implementation (orthogonal pairs)" do
      subject = %{
        "meta" => %{
          "id" => "x.subject",
          "realized_by" => %{
            "expanded_behavior" => ["Mod.a/1"],
            "use" => ["Mod.a/1"],
            "typespecs" => ["Mod.a/1"]
          }
        }
      }

      assert RealizedByDedupe.duplicates(subject) == []
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "handles missing or malformed input gracefully" do
      assert RealizedByDedupe.duplicates(nil) == []
      assert RealizedByDedupe.duplicates(%{}) == []
      assert RealizedByDedupe.duplicates(%{"meta" => %{}}) == []
      assert RealizedByDedupe.duplicates("nope") == []
    end

    @tag spec: "specled.realized_by.dedup_check_shared_seam"
    test "tier_pair/0 returns the inspected pair" do
      assert RealizedByDedupe.tier_pair() == {"api_boundary", "implementation"}
    end
  end

  describe "RealizedByDedupCheck.findings/2 finding shape" do
    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "emits one warning finding per cross-tier duplicate" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "id" => "x.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1"],
                "implementation" => ["Mod.a/1"]
              }
            }
          }
        ]
      }

      [finding] = RealizedByDedupCheck.findings(index)

      assert finding["code"] == "realized_by_redundant_dup"
      assert finding["severity"] == "warning"
      assert finding["subject_id"] == "x.subject"
      assert finding["file"] == ".spec/specs/x.spec.md"
      # Names the entry and the subject + remediation pointer per requirement.
      assert finding["message"] =~ "Mod.a/1"
      assert finding["message"] =~ "x.subject"
      assert finding["message"] =~ "mix spec.dedup_realized_by"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "emits no findings when there are no duplicates" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "id" => "x.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1"],
                "implementation" => ["Mod.b/2"]
              }
            }
          }
        ]
      }

      assert RealizedByDedupCheck.findings(index) == []
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "emits no findings when the index has no subjects" do
      assert RealizedByDedupCheck.findings(%{}) == []
      assert RealizedByDedupCheck.findings(%{"subjects" => []}) == []
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "default severity is :warning; severity arg overrides for finding shape" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "id" => "x.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1"],
                "implementation" => ["Mod.a/1"]
              }
            }
          }
        ]
      }

      [finding] = RealizedByDedupCheck.findings(index)
      assert finding["severity"] == "warning"

      [info_finding] = RealizedByDedupCheck.findings(index, :info)
      assert info_finding["severity"] == "info"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "subject_id falls back to file when meta.id is missing" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1"],
                "implementation" => ["Mod.a/1"]
              }
            }
          }
        ]
      }

      [finding] = RealizedByDedupCheck.findings(index)
      assert finding["subject_id"] == ".spec/specs/x.spec.md"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "finding_code/0 returns realized_by_redundant_dup" do
      assert RealizedByDedupCheck.finding_code() == "realized_by_redundant_dup"
    end
  end

  describe "RealizedByDedupCheck.findings/2 per-form message variants" do
    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "MFA-form duplicates name the strict-subset hash relationship" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "id" => "x.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1"],
                "implementation" => ["Mod.a/1"]
              }
            }
          }
        ]
      }

      [finding] = RealizedByDedupCheck.findings(index)

      assert finding["message"] =~ "strict subset"
      # MFA-form message is distinct from bare-module form: it does NOT
      # mention head-union vs full-union.
      refute finding["message"] =~ "head-union"
      refute finding["message"] =~ "full-union"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "bare-module-form duplicates name the head-union vs full-union split" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "id" => "x.subject",
              "realized_by" => %{
                "api_boundary" => ["SpecLedEx.Coverage"],
                "implementation" => ["SpecLedEx.Coverage"]
              }
            }
          }
        ]
      }

      [finding] = RealizedByDedupCheck.findings(index)

      assert finding["message"] =~ "head-union"
      assert finding["message"] =~ "full-union"
      # Bare-module form does NOT use the strict-subset framing.
      refute finding["message"] =~ "strict subset"
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "all variants include the dedup remediation pointer" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/x.spec.md",
            "meta" => %{
              "id" => "x.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1", "BareMod"],
                "implementation" => ["Mod.a/1", "BareMod"]
              }
            }
          }
        ]
      }

      findings = RealizedByDedupCheck.findings(index)
      assert length(findings) == 2

      for finding <- findings do
        assert finding["message"] =~ "mix spec.dedup_realized_by"
      end
    end

    @tag spec: "specled.realized_by.redundant_dup_warning"
    test "multiple subjects each get their own finding" do
      index = %{
        "subjects" => [
          %{
            "file" => ".spec/specs/a.spec.md",
            "meta" => %{
              "id" => "a.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.a/1"],
                "implementation" => ["Mod.a/1"]
              }
            }
          },
          %{
            "file" => ".spec/specs/b.spec.md",
            "meta" => %{
              "id" => "b.subject",
              "realized_by" => %{
                "api_boundary" => ["Mod.b/2"],
                "implementation" => ["Mod.b/2"]
              }
            }
          }
        ]
      }

      findings = RealizedByDedupCheck.findings(index)
      assert length(findings) == 2
      subjects = findings |> Enum.map(& &1["subject_id"]) |> Enum.sort()
      assert subjects == ["a.subject", "b.subject"]
    end
  end
end
