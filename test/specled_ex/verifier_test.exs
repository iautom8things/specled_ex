defmodule SpecLedEx.VerifierTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.decisions.change_type_enum", "specled.decisions.change_type_optional", "specled.decisions.cross_field_adr_append_only", "specled.decisions.cross_field_affects_non_empty", "specled.decisions.cross_field_affects_resolve", "specled.decisions.cross_field_idempotent", "specled.decisions.cross_field_reverses_what", "specled.decisions.cross_field_supersedes_replaces", "specled.decisions.frontmatter_contract", "specled.decisions.reference_validation", "specled.decisions.weakening_set", "specled.verify.command_execution_resilience", "specled.verify.command_exit_code_recorded", "specled.verify.command_output_via_tempfile", "specled.verify.command_timeout_enforced", "specled.verify.coverage_warnings", "specled.verify.decision_governance", "specled.verify.malformed_entries_nonfatal", "specled.verify.meta_required", "specled.verify.reference_checks", "specled.verify.strength_semantics", "specled.verify.target_existence"]

  alias SpecLedEx.Verifier

  test "verify reports parse errors and missing meta fields", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            %{
              "file" => ".spec/specs/missing_meta.spec.md",
              "meta" => %{},
              "parse_errors" => ["spec-meta decode failed: broken yaml"]
            }
          ]
        },
        root,
        debug: true
      )

    assert report["status"] == "fail"
    assert report["summary"]["errors"] == 4

    assert finding_codes(report) ==
             MapSet.new([
               "missing_meta_field",
               "parse_error"
             ])

    assert check_codes(report) ==
             MapSet.new([
               "duplicate_decision_id",
               "meta_field_missing",
               "parse_blocks",
               "duplicate_subject_id",
               "duplicate_requirement_id"
             ])
  end

  test "verify ignores malformed non-map items instead of crashing", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            %{
              "file" => ".spec/specs/malformed.spec.md",
              "meta" => %{"id" => "malformed.subject", "kind" => "module", "status" => "active"},
              "requirements" => ["bad requirement"],
              "scenarios" => ["bad scenario"],
              "verification" => ["bad verification"],
              "exceptions" => ["bad exception"],
              "parse_errors" => [
                "spec-requirements[0] validation failed: invalid type: expected map"
              ]
            }
          ]
        },
        root,
        debug: true
      )

    assert report["status"] == "fail"
    assert finding_codes(report) == MapSet.new(["parse_error"])

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "parse_blocks" and &1["status"] == "error")
           )
  end

  test "verify reports requirement and scenario structure issues", %{root: root} do
    report =
      verify_subject(
        root,
        %{
          "requirements" => [
            %{"statement" => "Missing id"},
            %{"id" => "covered.req", "statement" => "Covered"}
          ],
          "scenarios" => [
            %{
              "id" => "scenario.bad",
              "covers" => ["unknown.req"],
              "given" => [],
              "when" => [],
              "then" => []
            },
            %{
              "covers" => [],
              "given" => ["g"],
              "when" => ["w"],
              "then" => ["t"]
            }
          ]
        }
      )

    assert report["summary"]["warnings"] == 5
    assert report["summary"]["errors"] == 2

    assert finding_codes(report) ==
             MapSet.new([
               "missing_requirement_id",
               "missing_scenario_id",
               "scenario_unknown_cover",
               "scenario_missing_given",
               "scenario_missing_when",
               "scenario_missing_then",
               "requirement_without_verification"
             ])
  end

  test "verify reports duplicate ids and invalid id formats", %{root: root} do
    duplicate_subject =
      base_subject(%{
        "meta" => %{"id" => "duplicate.subject", "kind" => "module", "status" => "active"},
        "requirements" => [%{"id" => "duplicate.requirement", "statement" => "One"}],
        "scenarios" => [
          %{
            "id" => "duplicate.scenario",
            "covers" => [],
            "given" => ["given"],
            "when" => ["when"],
            "then" => ["then"]
          }
        ],
        "exceptions" => [%{"id" => "duplicate.exception", "covers" => [], "reason" => "waived"}]
      })

    invalid_subject =
      base_subject(%{
        "file" => ".spec/specs/invalid.spec.md",
        "meta" => %{"id" => "Bad Subject", "kind" => "module", "status" => "active"},
        "requirements" => [%{"id" => "Bad Requirement", "statement" => "Bad"}],
        "scenarios" => [
          %{
            "id" => "Bad Scenario",
            "covers" => [],
            "given" => ["given"],
            "when" => ["when"],
            "then" => ["then"]
          }
        ],
        "exceptions" => [%{"id" => "Bad Exception", "covers" => [], "reason" => "waived"}]
      })

    report =
      Verifier.verify(
        %{"subjects" => [duplicate_subject, duplicate_subject, invalid_subject]},
        root,
        debug: true
      )

    assert finding_codes(report) ==
             MapSet.new([
               "duplicate_subject_id",
               "duplicate_requirement_id",
               "duplicate_scenario_id",
               "duplicate_exception_id",
               "invalid_id_format",
               "requirement_without_verification"
             ])

    assert Enum.count(report["findings"], &(&1["code"] == "invalid_id_format")) == 4

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "duplicate_subject_id" and &1["status"] == "error")
           )

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "duplicate_requirement_id" and &1["status"] == "error")
           )
  end

  test "verify evaluates file and command verifications with debug checks", %{root: root} do
    write_files(root, %{"present.txt" => "present"})

    report =
      verify_subject(
        root,
        %{
          "requirements" => [
            %{"id" => "req.1", "statement" => "Covered"},
            %{"id" => "req.2", "statement" => "Covered by exception"}
          ],
          "verification" => [
            %{"kind" => "source_file", "target" => "present.txt", "covers" => ["req.1"]},
            %{"kind" => "source_file", "target" => "missing.txt", "covers" => ["req.1"]},
            %{"kind" => "source_file", "target" => "", "covers" => []},
            %{
              "kind" => "command",
              "target" => "printf ok",
              "covers" => ["req.1"],
              "execute" => true
            },
            %{
              "kind" => "command",
              "target" => "printf boom && exit 2",
              "covers" => ["req.1"],
              "execute" => true
            },
            %{
              "kind" => "command",
              "target" => "printf skip",
              "covers" => ["req.1"],
              "execute" => false
            },
            %{"kind" => "command", "target" => "", "covers" => []},
            %{
              "kind" => "command",
              "target" => "printf noop",
              "covers" => ["unknown.claim"],
              "execute" => false
            }
          ],
          "exceptions" => [
            %{"id" => "exception.one", "covers" => ["req.2"], "reason" => "accepted"}
          ]
        },
        debug: true,
        run_commands: true
      )

    assert report["status"] == "fail"

    assert finding_codes(report) ==
             MapSet.new([
               "verification_missing_target",
               "verification_target_missing",
               "verification_command_failed",
               "verification_missing_command",
               "verification_unknown_cover",
               "verification_target_missing_reference"
             ])

    assert Enum.any?(checks(report, "verification_target_exists"), &(&1["status"] == "pass"))
    assert Enum.any?(checks(report, "verification_command_passed"), &(&1["status"] == "pass"))
    assert Enum.any?(checks(report, "verification_command_skipped"), &(&1["status"] == "pass"))
    assert Enum.any?(checks(report, "verification_command_failed"), &(&1["status"] == "error"))
    assert Enum.any?(checks(report, "verification_cover_valid"), &(&1["status"] == "pass"))
    assert Enum.any?(checks(report, "verification_cover_unknown"), &(&1["status"] == "warning"))
  end

  test "verify reports unknown verification kinds and excludes them from coverage", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.typo", "statement" => "Must be covered"}],
              "verification" => [
                %{"kind" => "typo_kind", "target" => "ignored", "covers" => ["req.typo"]}
              ]
            })
          ]
        },
        root,
        debug: true
      )

    assert report["status"] == "fail"
    assert report["summary"]["errors"] == 1
    assert report["summary"]["warnings"] == 1

    assert finding_codes(report) ==
             MapSet.new([
               "verification_unknown_kind",
               "requirement_without_verification"
             ])

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "verification_kind_invalid" and &1["status"] == "error")
           )
  end

  test "verify only executes command verifications once in debug mode", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.run", "statement" => "Run exactly once"}],
              "verification" => [
                %{
                  "kind" => "command",
                  "target" => "printf run >> runs.txt",
                  "covers" => ["req.run"],
                  "execute" => true
                }
              ]
            })
          ]
        },
        root,
        debug: true,
        run_commands: true
      )

    assert report["status"] == "pass"
    assert File.read!(Path.join(root, "runs.txt")) == "run"
  end

  test "verify validates decisions and subject decision references", %{root: root} do
    valid_subject =
      base_subject(%{
        "meta" => %{
          "id" => "package.subject",
          "kind" => "module",
          "status" => "active",
          "decisions" => ["repo.governance.policy"]
        }
      })

    invalid_subject =
      base_subject(%{
        "file" => ".spec/specs/other.spec.md",
        "meta" => %{
          "id" => "other.subject",
          "kind" => "module",
          "status" => "active",
          "decisions" => ["repo.governance.missing"]
        }
      })

    report =
      Verifier.verify(
        %{
          "subjects" => [valid_subject, invalid_subject],
          "decisions" => [
            %{
              "file" => ".spec/decisions/governance.md",
              "meta" => %{
                "id" => "repo.governance.policy",
                "status" => "accepted",
                "date" => "2026-03-11",
                "affects" => ["repo.governance", "package.subject"]
              },
              "sections" => ["Context", "Decision", "Consequences"],
              "parse_errors" => []
            },
            %{
              "file" => ".spec/decisions/bad.md",
              "meta" => %{
                "id" => "repo.governance.bad",
                "status" => "superseded",
                "date" => "bad-date",
                "affects" => ["missing.subject"]
              },
              "sections" => ["Context", "Decision"],
              "parse_errors" => []
            }
          ]
        },
        root,
        debug: true
      )

    assert report["status"] == "fail"

    assert finding_codes(report) ==
             MapSet.new([
               "decision_invalid_date",
               "decision_missing_section",
               "decision_missing_superseded_by",
               "decision_unknown_affect",
               "subject_unknown_decision_reference"
             ])

    assert Enum.any?(report["checks"], &(&1["code"] == "decision_section_missing"))
    assert Enum.any?(report["checks"], &(&1["code"] == "decision_affect_invalid"))
  end

  test "verify only fails warnings in strict mode", %{root: root} do
    index = %{
      "subjects" => [
        base_subject(%{"requirements" => [%{"id" => "req.only", "statement" => "Uncovered"}]})
      ]
    }

    non_strict = Verifier.verify(index, root)
    strict = Verifier.verify(index, root, strict: true)

    assert non_strict["status"] == "pass"
    assert strict["status"] == "fail"
    assert non_strict["summary"]["warnings"] == 1
    assert strict["summary"]["warnings"] == 1
  end

  test "verify emits pass-oriented debug checks for clean subjects", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.clean", "statement" => "Covered"}],
              "scenarios" => [
                %{
                  "id" => "scenario.clean",
                  "covers" => ["req.clean"],
                  "given" => ["given"],
                  "when" => ["when"],
                  "then" => ["then"]
                }
              ],
              "verification" => [
                %{"kind" => "command", "target" => "mix test", "covers" => ["req.clean"]}
              ]
            })
          ]
        },
        root,
        debug: true
      )

    assert report["status"] == "pass"
    assert report["summary"]["warnings"] == 0

    assert check_codes(report) ==
             MapSet.new([
               "duplicate_decision_id",
               "meta_field_present",
               "parse_blocks",
               "requirement_id_present",
               "scenario_id_present",
               "scenario_cover_valid",
               "verification_command_present",
               "verification_cover_valid",
               "requirement_has_verification",
               "duplicate_subject_id",
               "duplicate_requirement_id"
             ])
  end

  test "verify resolves cross-subject covers references without warnings", %{root: root} do
    subject_a =
      base_subject(%{
        "file" => ".spec/specs/a.spec.md",
        "meta" => %{"id" => "subject.a", "kind" => "module", "status" => "active"},
        "requirements" => [%{"id" => "req.from_a", "statement" => "Defined in A"}]
      })

    subject_b =
      base_subject(%{
        "file" => ".spec/specs/b.spec.md",
        "meta" => %{"id" => "subject.b", "kind" => "module", "status" => "active"},
        "requirements" => [%{"id" => "req.from_b", "statement" => "Defined in B"}],
        "verification" => [
          %{"kind" => "command", "target" => "mix test", "covers" => ["req.from_b", "req.from_a"]}
        ]
      })

    report = verify_subjects(root, [subject_a, subject_b])

    refute Enum.any?(report["findings"], &(&1["code"] == "verification_unknown_cover"))
  end

  test "verify warns on truly unknown cross-subject covers references", %{root: root} do
    subject_a =
      base_subject(%{
        "file" => ".spec/specs/a.spec.md",
        "meta" => %{"id" => "subject.a", "kind" => "module", "status" => "active"},
        "requirements" => [%{"id" => "req.exists", "statement" => "Exists"}],
        "verification" => [
          %{
            "kind" => "command",
            "target" => "mix test",
            "covers" => ["req.exists", "req.nowhere"]
          }
        ]
      })

    report = verify_subjects(root, [subject_a])

    unknown_covers = findings(report, "verification_unknown_cover")

    assert length(unknown_covers) == 1
    assert hd(unknown_covers)["message"] =~ "req.nowhere"
  end

  test "verify cross-subject covers works in debug mode", %{root: root} do
    subject_a =
      base_subject(%{
        "file" => ".spec/specs/a.spec.md",
        "meta" => %{"id" => "subject.a", "kind" => "module", "status" => "active"},
        "requirements" => [%{"id" => "req.from_a", "statement" => "From A"}]
      })

    subject_b =
      base_subject(%{
        "file" => ".spec/specs/b.spec.md",
        "meta" => %{"id" => "subject.b", "kind" => "module", "status" => "active"},
        "verification" => [
          %{"kind" => "command", "target" => "mix test", "covers" => ["req.from_a"]}
        ]
      })

    report = verify_subjects(root, [subject_a, subject_b], debug: true)

    cross_subject_checks =
      Enum.filter(checks(report, "verification_cover_valid"), &String.contains?(&1["message"], "cross-subject"))

    assert length(cross_subject_checks) == 1
    assert hd(cross_subject_checks)["message"] =~ "req.from_a"
  end

  test "verify warns when surface paths do not exist", %{root: root} do
    write_files(root, %{"lib/real.ex" => "defmodule Real do end"})

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "meta" => %{
                "id" => "surface.test",
                "kind" => "module",
                "status" => "active",
                "surface" => ["lib/real.ex", "lib/missing.ex"]
              }
            })
          ]
        },
        root
      )

    surface_findings =
      Enum.filter(report["findings"], &(&1["code"] == "surface_target_missing"))

    assert length(surface_findings) == 1
    assert hd(surface_findings)["message"] =~ "lib/missing.ex"
  end

  test "verify does not warn for non-path surface entries", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "meta" => %{
                "id" => "surface.nonpath",
                "kind" => "endpoint",
                "status" => "active",
                "surface" => ["GET /api/greeting"]
              }
            })
          ]
        },
        root
      )

    refute Enum.any?(report["findings"], &(&1["code"] == "surface_target_missing"))
  end

  test "verify surface checks work in debug mode", %{root: root} do
    write_files(root, %{"lib/exists.ex" => "defmodule Exists do end"})

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "meta" => %{
                "id" => "surface.debug",
                "kind" => "module",
                "status" => "active",
                "surface" => ["lib/exists.ex", "lib/gone.ex", "GET /api/health"]
              }
            })
          ]
        },
        root,
        debug: true
      )

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "surface_target_exists" and &1["message"] =~ "lib/exists.ex")
           )

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "surface_target_missing" and &1["message"] =~ "lib/gone.ex")
           )

    assert Enum.any?(
             report["checks"],
             &(&1["code"] == "surface_target_skipped" and &1["message"] =~ "GET /api/health")
           )
  end

  test "verify emits warning finding when target file does not reference covered requirement", %{
    root: root
  } do
    write_files(root, %{
      "test/my_test.exs" => """
      defmodule MyTest do
        use ExUnit.Case
        test "it works" do
          assert true
        end
      end
      """
    })

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.greeting", "statement" => "Must greet"}],
              "verification" => [
                %{
                  "kind" => "test_file",
                  "target" => "test/my_test.exs",
                  "covers" => ["req.greeting"]
                }
              ]
            })
          ]
        },
        root
      )

    content_findings = findings(report, "verification_target_missing_reference")

    assert length(content_findings) == 1
    assert hd(content_findings)["severity"] == "warning"
    assert hd(content_findings)["message"] =~ "req.greeting"
    assert hd(content_findings)["message"] =~ "test/my_test.exs"
    assert report["verification"]["strength_summary"]["claimed"] == 1
  end

  test "verify does not emit content finding when target file references requirement id", %{
    root: root
  } do
    write_files(root, %{
      "test/greeting_test.exs" => """
      defmodule GreetingTest do
        use ExUnit.Case
        # covers: req.greeting
        test "it greets" do
          assert Greeting.hello("Ada") == "Hello, Ada"
        end
      end
      """
    })

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.greeting", "statement" => "Must greet"}],
              "verification" => [
                %{
                  "kind" => "test_file",
                  "target" => "test/greeting_test.exs",
                  "covers" => ["req.greeting"]
                }
              ]
            })
          ]
        },
        root
      )

    assert findings(report, "verification_target_missing_reference") == []

    assert report["verification"]["strength_summary"]["linked"] == 1
  end

  test "verify skips content probe when target file does not exist", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.gone", "statement" => "Missing file"}],
              "verification" => [
                %{
                  "kind" => "source_file",
                  "target" => "lib/gone.ex",
                  "covers" => ["req.gone"]
                }
              ]
            })
          ]
        },
        root
      )

    assert findings(report, "verification_target_missing_reference") == []
    assert findings(report, "verification_target_missing") != []
  end

  test "verify skips content probe for command verification kind", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.cmd", "statement" => "Run command"}],
              "verification" => [
                %{"kind" => "command", "target" => "mix test", "covers" => ["req.cmd"]}
              ]
            })
          ]
        },
        root
      )

    assert findings(report, "verification_target_missing_reference") == []
  end

  test "verify content probe does not affect pass/fail status", %{root: root} do
    write_files(root, %{"lib/code.ex" => "defmodule Code do end"})

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.info", "statement" => "Covered"}],
              "verification" => [
                %{
                  "kind" => "source_file",
                  "target" => "lib/code.ex",
                  "covers" => ["req.info"]
                }
              ]
            })
          ]
        },
        root
      )

    assert report["status"] == "pass"

    assert findings(report, "verification_target_missing_reference") != []
  end

  test "verify content probe warning findings fail in strict mode", %{root: root} do
    write_files(root, %{"lib/code.ex" => "defmodule Code do end"})

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.strict", "statement" => "Covered"}],
              "verification" => [
                %{
                  "kind" => "source_file",
                  "target" => "lib/code.ex",
                  "covers" => ["req.strict"]
                }
              ]
            })
          ]
        },
        root,
        strict: true
      )

    assert report["status"] == "fail"
  end

  test "verify reports linked strength below an executed CLI minimum", %{root: root} do
    write_files(root, %{"lib/linked.ex" => "# req.threshold\n"})

    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "meta" => %{
                "id" => "threshold.subject",
                "kind" => "module",
                "status" => "active",
                "verification_minimum_strength" => "linked"
              },
              "requirements" => [%{"id" => "req.threshold", "statement" => "Covered"}],
              "verification" => [
                %{
                  "kind" => "source_file",
                  "target" => "lib/linked.ex",
                  "covers" => ["req.threshold"]
                }
              ]
            })
          ]
        },
        root,
        min_strength: "executed"
      )

    assert report["status"] == "fail"
    assert report["verification"]["cli_minimum_strength"] == "executed"
    assert report["verification"]["threshold_failures"] == 1

    assert claim_for(report, "req.threshold") == %{
             "cover_id" => "req.threshold",
             "file" => ".spec/specs/example.spec.md",
             "kind" => "source_file",
             "meets_minimum" => false,
             "required_strength" => "executed",
             "strength" => "linked",
             "subject_id" => "threshold.subject",
             "target" => "lib/linked.ex",
             "verification_index" => 0
           }

    assert findings(report, "verification_strength_below_minimum") != []
  end

  test "verify reports executed strength for successful commands", %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "meta" => %{
                "id" => "executed.subject",
                "kind" => "module",
                "status" => "active",
                "verification_minimum_strength" => "executed"
              },
              "requirements" => [%{"id" => "req.executed", "statement" => "Executed"}],
              "verification" => [
                %{
                  "kind" => "command",
                  "target" => "printf ok",
                  "covers" => ["req.executed"],
                  "execute" => true
                }
              ]
            })
          ]
        },
        root,
        run_commands: true
      )

    assert report["status"] == "pass"
    assert report["verification"]["strength_summary"]["executed"] == 1
    assert report["verification"]["threshold_failures"] == 0

    claim = claim_for(report, "req.executed")

    assert claim["strength"] == "executed"
    assert claim["required_strength"] == "executed"
    assert claim["meets_minimum"]
  end

  # ── command execution resilience ──────────────────────────────────────────

  test "command verification captures output via temp files", %{root: root} do
    report =
      verify_subject(
        root,
        %{
          "requirements" => [%{"id" => "req.cmd", "statement" => "Command runs"}],
          "verification" => [
            %{
              "kind" => "command",
              "target" => "printf 'hello from command'",
              "covers" => ["req.cmd"],
              "execute" => true
            }
          ]
        },
        run_commands: true,
        debug: true
      )

    assert report["status"] == "pass"

    passed_check =
      Enum.find(report["checks"], fn c ->
        c["code"] == "verification_command_passed" and c["status"] == "pass"
      end)

    assert passed_check
  end

  test "command verification captures non-zero exit codes", %{root: root} do
    report =
      verify_subject(
        root,
        %{
          "requirements" => [%{"id" => "req.fail", "statement" => "Fails"}],
          "verification" => [
            %{
              "kind" => "command",
              "target" => "exit 2",
              "covers" => ["req.fail"],
              "execute" => true
            }
          ]
        },
        run_commands: true,
        debug: true
      )

    assert report["status"] == "fail"

    failed_check =
      Enum.find(report["checks"], fn c ->
        c["code"] == "verification_command_failed" and c["status"] == "error"
      end)

    assert failed_check
  end

  test "command verification times out on slow commands", %{root: root} do
    report =
      verify_subject(
        root,
        %{
          "requirements" => [%{"id" => "req.slow", "statement" => "Slow"}],
          "verification" => [
            %{
              "kind" => "command",
              "target" => "sleep 30",
              "covers" => ["req.slow"],
              "execute" => true
            }
          ]
        },
        run_commands: true,
        command_timeout_ms: 500,
        debug: true
      )

    assert report["status"] == "fail"

    failed_check =
      Enum.find(report["checks"], fn c ->
        c["code"] == "verification_command_failed" and c["status"] == "error"
      end)

    assert failed_check
  end

  # ── tagged_tests verification kind ───────────────────────────────────────

  @tag spec: "specled.tagged_tests.strength_progression"
  test "tagged_tests verification does not require a target and earns linked strength when tagged",
       %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [
                %{"id" => "req.alpha", "statement" => "Alpha"},
                %{"id" => "req.beta", "statement" => "Beta"}
              ],
              "verification" => [
                %{
                  "kind" => "tagged_tests",
                  "covers" => ["req.alpha", "req.beta"],
                  "execute" => false
                }
              ]
            })
          ],
          "test_tags" => %{
            "req.alpha" => [%{file: "test/alpha_test.exs", line: 3, test_name: "t1"}],
            "req.beta" => [%{file: "test/beta_test.exs", line: 4, test_name: "t2"}]
          }
        },
        root
      )

    assert report["status"] == "pass"

    claim_alpha = claim_for(report, "req.alpha")
    claim_beta = claim_for(report, "req.beta")

    assert claim_alpha["strength"] == "linked"
    assert claim_alpha["kind"] == "tagged_tests"
    assert claim_beta["strength"] == "linked"

    refute Enum.any?(report["findings"], &(&1["code"] == "verification_missing_target"))
  end

  @tag spec: "specled.tagged_tests.missing_tag_finding"
  @tag spec: "specled.tagged_tests.strength_claimed_on_untagged_cover"
  test "tagged_tests verification flags covers that have no @tag spec entry",
       %{root: root} do
    report =
      Verifier.verify(
        %{
          "subjects" => [
            base_subject(%{
              "requirements" => [%{"id" => "req.untagged", "statement" => "Untagged"}],
              "verification" => [
                %{
                  "kind" => "tagged_tests",
                  "covers" => ["req.untagged"]
                }
              ]
            })
          ],
          "test_tags" => %{}
        },
        root
      )

    assert Enum.any?(
             findings(report, "tagged_tests_cover_missing_tag"),
             &(&1["message"] =~ "req.untagged")
           )

    claim = claim_for(report, "req.untagged")
    assert claim["strength"] == "claimed"
  end

  @tag spec: "specled.tagged_tests.merged_run_attribution"
  @tag spec: "specled.tagged_tests.strength_executed_on_green_run"
  test "tagged_tests verifications across subjects are merged into one mix test invocation",
       %{root: root} do
    marker = Path.join(root, "tagged_tests_calls.txt")

    # Build a fake `mix` on PATH that appends its args to a marker file and
    # exits 0 — the merged command is `mix test --only spec:<id>... <files>`.
    shim_dir = Path.join(root, "bin")
    File.mkdir_p!(shim_dir)
    shim_path = Path.join(shim_dir, "mix")

    File.write!(shim_path, """
    #!/bin/sh
    echo "$@" >> "#{marker}"
    exit 0
    """)

    File.chmod!(shim_path, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", "#{shim_dir}:#{original_path}")

    try do
      report =
        Verifier.verify(
          %{
            "subjects" => [
              base_subject(%{
                "file" => ".spec/specs/alpha.spec.md",
                "meta" => %{"id" => "alpha", "kind" => "module", "status" => "active"},
                "requirements" => [%{"id" => "req.alpha", "statement" => "Alpha"}],
                "verification" => [
                  %{"kind" => "tagged_tests", "covers" => ["req.alpha"], "execute" => true}
                ]
              }),
              base_subject(%{
                "file" => ".spec/specs/beta.spec.md",
                "meta" => %{"id" => "beta", "kind" => "module", "status" => "active"},
                "requirements" => [%{"id" => "req.beta", "statement" => "Beta"}],
                "verification" => [
                  %{"kind" => "tagged_tests", "covers" => ["req.beta"], "execute" => true}
                ]
              })
            ],
            "test_tags" => %{
              "req.alpha" => [%{file: "test/alpha_test.exs", line: 3, test_name: "t1"}],
              "req.beta" => [%{file: "test/beta_test.exs", line: 4, test_name: "t2"}]
            }
          },
          root,
          run_commands: true
        )

      assert report["status"] == "pass"

      calls = File.read!(marker) |> String.trim() |> String.split("\n", trim: true)
      assert length(calls) == 1, "expected a single merged mix test invocation"

      [call] = calls
      assert call =~ "test"
      assert call =~ "--only spec:req.alpha"
      assert call =~ "--only spec:req.beta"
      assert call =~ "test/alpha_test.exs"
      assert call =~ "test/beta_test.exs"

      assert claim_for(report, "req.alpha")["strength"] == "executed"
      assert claim_for(report, "req.beta")["strength"] == "executed"
    after
      System.put_env("PATH", original_path)
    end
  end

  @tag spec: "specled.tagged_tests.merged_run_attribution"
  test "tagged_tests merged command failure surfaces a finding per subject",
       %{root: root} do
    shim_dir = Path.join(root, "bin")
    File.mkdir_p!(shim_dir)
    shim_path = Path.join(shim_dir, "mix")
    File.write!(shim_path, "#!/bin/sh\necho boom\nexit 2\n")
    File.chmod!(shim_path, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", "#{shim_dir}:#{original_path}")

    try do
      report =
        Verifier.verify(
          %{
            "subjects" => [
              base_subject(%{
                "file" => ".spec/specs/alpha.spec.md",
                "meta" => %{"id" => "alpha", "kind" => "module", "status" => "active"},
                "requirements" => [%{"id" => "req.alpha", "statement" => "Alpha"}],
                "verification" => [
                  %{"kind" => "tagged_tests", "covers" => ["req.alpha"], "execute" => true}
                ]
              }),
              base_subject(%{
                "file" => ".spec/specs/beta.spec.md",
                "meta" => %{"id" => "beta", "kind" => "module", "status" => "active"},
                "requirements" => [%{"id" => "req.beta", "statement" => "Beta"}],
                "verification" => [
                  %{"kind" => "tagged_tests", "covers" => ["req.beta"], "execute" => true}
                ]
              })
            ],
            "test_tags" => %{
              "req.alpha" => [%{file: "test/alpha_test.exs"}],
              "req.beta" => [%{file: "test/beta_test.exs"}]
            }
          },
          root,
          run_commands: true
        )

      assert report["status"] == "fail"

      failures = findings(report, "verification_command_failed")
      assert length(failures) == 2

      assert claim_for(report, "req.alpha")["strength"] == "linked"
      assert claim_for(report, "req.beta")["strength"] == "linked"
    after
      System.put_env("PATH", original_path)
    end
  end

  test "command verification writes output to temp files then cleans up", %{root: root} do
    report =
      verify_subject(
        root,
        %{
          "requirements" => [%{"id" => "req.out", "statement" => "Output captured"}],
          "verification" => [
            %{
              "kind" => "command",
              "target" => "printf run >> #{Path.join(root, "proof.txt")}",
              "covers" => ["req.out"],
              "execute" => true
            }
          ]
        },
        run_commands: true
      )

    assert report["status"] == "pass"
    assert File.read!(Path.join(root, "proof.txt")) == "run"
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

  defp finding_codes(report) do
    report["findings"]
    |> Enum.map(& &1["code"])
    |> MapSet.new()
  end

  defp findings(report, code) do
    Enum.filter(report["findings"], &(&1["code"] == code))
  end

  defp check_codes(report) do
    report["checks"]
    |> Enum.map(& &1["code"])
    |> MapSet.new()
  end

  defp checks(report, code) do
    Enum.filter(report["checks"], &(&1["code"] == code))
  end

  defp claim_for(report, cover_id) do
    Enum.find(report["verification"]["claims"], &(&1["cover_id"] == cover_id))
  end

  defp verify_subject(root, overrides, opts \\ []) do
    Verifier.verify(%{"subjects" => [base_subject(overrides)]}, root, opts)
  end

  defp verify_subjects(root, subjects, opts \\ []) do
    Verifier.verify(%{"subjects" => subjects}, root, opts)
  end
end
