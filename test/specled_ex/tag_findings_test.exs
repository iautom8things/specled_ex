defmodule SpecLedEx.TagFindingsTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.verify.requirement_without_test_tag", "specled.verify.tag_dynamic_value_skipped", "specled.verify.tag_findings_respect_enforcement", "specled.verify.tag_findings_suppressed_when_disabled", "specled.verify.tag_scan_parse_error", "specled.verify.verification_cover_untagged"]

  alias SpecLedEx.Verifier

  @tag spec: "specled.verify.requirement_without_test_tag"
  test "emits requirement_without_test_tag for must requirements covered by tagged_tests without a backing tag",
       %{root: root} do
    index = %{
      "subjects" => [
        base_subject(%{
          "requirements" => [
            %{"id" => "billing.invoice", "statement" => "Must invoice", "priority" => "must"},
            %{"id" => "billing.refund", "statement" => "Should refund", "priority" => "should"}
          ],
          "verification" => [
            %{
              "kind" => "tagged_tests",
              "covers" => ["billing.invoice"],
              "execute" => true
            }
          ]
        })
      ],
      "test_tags" => %{"other.requirement" => []},
      "test_tags_errors" => [],
      "test_tags_dynamic" => [],
      "test_tags_config" => %{
        "enabled" => true,
        "paths" => ["test"],
        "enforcement" => "warning"
      }
    }

    report = Verifier.verify(index, root)

    tag_findings = findings(report, "requirement_without_test_tag")
    assert length(tag_findings) == 1
    assert hd(tag_findings)["severity"] == "warning"
    assert hd(tag_findings)["message"] =~ "billing.invoice"
  end

  @tag spec: "specled.verify.requirement_without_test_tag"
  test "skips requirement_without_test_tag when the requirement is covered only by non-tagged_tests kinds",
       %{root: root} do
    index = %{
      "subjects" => [
        base_subject(%{
          "requirements" => [
            %{
              "id" => "docs.readme_present",
              "statement" => "README must exist",
              "priority" => "must"
            }
          ],
          "verification" => [
            %{
              "kind" => "source_file",
              "target" => ".spec/README.md",
              "covers" => ["docs.readme_present"]
            }
          ]
        })
      ],
      "test_tags" => %{},
      "test_tags_errors" => [],
      "test_tags_dynamic" => [],
      "test_tags_config" => %{
        "enabled" => true,
        "paths" => ["test"],
        "enforcement" => "warning"
      }
    }

    report = Verifier.verify(index, root)

    assert findings(report, "requirement_without_test_tag") == []
  end

  @tag spec: "specled.verify.verification_cover_untagged"
  test "emits verification_cover_untagged when test_file target lacks a matching @tag spec", %{
    root: root
  } do
    index = %{
      "subjects" => [
        base_subject(%{
          "requirements" => [
            %{"id" => "billing.invoice", "statement" => "Must invoice", "priority" => "must"}
          ],
          "verification" => [
            %{
              "kind" => "test_file",
              "target" => "test/billing_test.exs",
              "covers" => ["billing.invoice"]
            }
          ]
        })
      ],
      "test_tags" => %{
        "billing.invoice" => [
          %{id: "billing.invoice", file: "test/other_test.exs", line: 3, test_name: "elsewhere"}
        ]
      },
      "test_tags_errors" => [],
      "test_tags_dynamic" => [],
      "test_tags_config" => %{
        "enabled" => true,
        "paths" => ["test"],
        "enforcement" => "warning"
      }
    }

    report = Verifier.verify(index, root)

    cover_findings = findings(report, "verification_cover_untagged")
    assert length(cover_findings) == 1
    assert hd(cover_findings)["severity"] == "warning"
    assert hd(cover_findings)["message"] =~ "test/billing_test.exs"
    assert hd(cover_findings)["message"] =~ "billing.invoice"
  end

  @tag spec: "specled.verify.tag_scan_parse_error"
  test "emits tag_scan_parse_error for each unparseable file reported by the scanner", %{
    root: root
  } do
    index = %{
      "subjects" => [base_subject(%{})],
      "test_tags" => %{},
      "test_tags_errors" => [
        %{file: "test/broken.exs", reason: "syntax error"}
      ],
      "test_tags_dynamic" => [],
      "test_tags_config" => %{
        "enabled" => true,
        "paths" => ["test"],
        "enforcement" => "warning"
      }
    }

    report = Verifier.verify(index, root)

    parse_error_findings = findings(report, "tag_scan_parse_error")
    assert length(parse_error_findings) == 1
    assert hd(parse_error_findings)["severity"] == "warning"
    assert hd(parse_error_findings)["message"] =~ "test/broken.exs"
  end

  @tag spec: "specled.verify.tag_dynamic_value_skipped"
  test "emits tag_dynamic_value_skipped for each dynamic @tag spec entry", %{root: root} do
    index = %{
      "subjects" => [base_subject(%{})],
      "test_tags" => %{},
      "test_tags_errors" => [],
      "test_tags_dynamic" => [
        %{file: "test/dynamic_test.exs", line: 12, test_name: "needs literal"}
      ],
      "test_tags_config" => %{
        "enabled" => true,
        "paths" => ["test"],
        "enforcement" => "warning"
      }
    }

    report = Verifier.verify(index, root)

    dynamic_findings = findings(report, "tag_dynamic_value_skipped")
    assert length(dynamic_findings) == 1
    assert hd(dynamic_findings)["severity"] == "warning"
    assert hd(dynamic_findings)["message"] =~ "test/dynamic_test.exs"
  end

  @tag spec: "specled.verify.tag_findings_respect_enforcement"
  test "promotes requirement_without_test_tag severity to error under enforcement=error", %{
    root: root
  } do
    index = %{
      "subjects" => [
        base_subject(%{
          "requirements" => [
            %{"id" => "billing.invoice", "statement" => "Must invoice", "priority" => "must"}
          ],
          "verification" => [
            %{
              "kind" => "tagged_tests",
              "covers" => ["billing.invoice"],
              "execute" => true
            }
          ]
        })
      ],
      "test_tags" => %{},
      "test_tags_errors" => [],
      "test_tags_dynamic" => [],
      "test_tags_config" => %{
        "enabled" => true,
        "paths" => ["test"],
        "enforcement" => "error"
      }
    }

    report = Verifier.verify(index, root)

    tag_findings = findings(report, "requirement_without_test_tag")
    assert length(tag_findings) == 1
    assert hd(tag_findings)["severity"] == "error"
    assert report["status"] == "fail"
  end

  @tag spec: "specled.verify.tag_findings_suppressed_when_disabled"
  test "emits no tag findings when index has no test_tags key", %{root: root} do
    index = %{
      "subjects" => [
        base_subject(%{
          "requirements" => [
            %{"id" => "billing.invoice", "statement" => "Must invoice", "priority" => "must"}
          ],
          "verification" => [
            %{
              "kind" => "test_file",
              "target" => "test/billing_test.exs",
              "covers" => ["billing.invoice"]
            }
          ]
        })
      ]
    }

    report = Verifier.verify(index, root)

    for code <- [
          "requirement_without_test_tag",
          "verification_cover_untagged",
          "tag_scan_parse_error",
          "tag_dynamic_value_skipped"
        ] do
      assert findings(report, code) == [], "expected no #{code} findings"
    end
  end

  defp base_subject(overrides) do
    Map.merge(
      %{
        "file" => ".spec/specs/example.spec.md",
        "meta" => %{"id" => "example.subject", "kind" => "module", "status" => "active"},
        "requirements" => [],
        "scenarios" => [],
        "verification" => [],
        "exceptions" => [],
        "parse_errors" => []
      },
      overrides
    )
  end

  defp findings(report, code) do
    Enum.filter(report["findings"], &(&1["code"] == code))
  end
end
