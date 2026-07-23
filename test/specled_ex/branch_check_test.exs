defmodule SpecLedEx.BranchCheckTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.branch_guard.new_requirement_tag_warning",
               "specled.branch_guard.tag_findings_respect_enforcement"
             ]

  alias SpecLedEx.{BranchCheck, Index}

  @moduletag :capture_log

  @tag spec: [
         "specled.branch_guard.new_requirement_tag_warning",
         "specled.branch_guard.status_follows_error_severity"
       ]
  test "emits finding when a new must requirement lacks a backing @tag spec", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
        enforcement: warning
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ],
      verification: [
        %{
          "kind" => "tagged_tests",
          "covers" => ["billing.list", "billing.invoice"],
          "execute" => true
        }
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    findings =
      Enum.filter(
        report["findings"],
        &(&1["code"] == "branch_guard_requirement_without_test_tag")
      )

    assert length(findings) == 1
    assert hd(findings)["severity"] == "warning"
    assert hd(findings)["message"] =~ "billing.invoice"
    assert hd(findings)["file"] == ".spec/specs/billing.spec.md"
    assert report["status"] == "pass"
  end

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "does not emit finding when the new must requirement is already tagged", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
      """,
      "test/billing_test.exs" => """
      defmodule BillingTest do
        use ExUnit.Case

        @tag spec: "billing.invoice"
        test "covers billing.invoice" do
          assert true
        end
      end
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    refute Enum.any?(
             report["findings"],
             &(&1["code"] == "branch_guard_requirement_without_test_tag")
           )
  end

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "does not emit finding when the new must requirement is covered only by a non-tagged_tests verification",
       %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.docs_ready", "statement" => "Docs ready", "priority" => "must"}
      ],
      verification: [
        %{
          "kind" => "source_file",
          "target" => ".spec/specs/billing.spec.md",
          "covers" => ["billing.docs_ready"]
        }
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    refute Enum.any?(
             report["findings"],
             &(&1["code"] == "branch_guard_requirement_without_test_tag")
           )
  end

  @tag spec: "specled.branch_guard.tag_findings_respect_enforcement"
  test "promotes finding severity to error under enforcement=error", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      test_tags:
        enabled: true
        paths:
          - test
        enforcement: error
      """
    })

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ],
      verification: [
        %{
          "kind" => "tagged_tests",
          "covers" => ["billing.list", "billing.invoice"],
          "execute" => true
        }
      ]
    )

    index = Index.build(root)
    report = BranchCheck.run(index, root, base: "HEAD")

    findings =
      Enum.filter(
        report["findings"],
        &(&1["code"] == "branch_guard_requirement_without_test_tag")
      )

    assert length(findings) == 1
    assert hd(findings)["severity"] == "error"
    assert report["status"] == "fail"
  end

  @tag spec: "specled.branch_guard.new_requirement_tag_warning"
  test "emits no tag findings when the index has no test_tags key", %{root: root} do
    init_git_repo(root)

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"}
      ]
    )

    commit_all(root, "initial")

    write_subject_spec(
      root,
      "billing",
      meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{"id" => "billing.list", "statement" => "Initial requirement", "priority" => "must"},
        %{"id" => "billing.invoice", "statement" => "Newly added", "priority" => "must"}
      ]
    )

    index = Index.build(root)
    refute Map.has_key?(index, "test_tags")

    report = BranchCheck.run(index, root, base: "HEAD")

    refute Enum.any?(
             report["findings"],
             &(&1["code"] == "branch_guard_requirement_without_test_tag")
           )
  end

  describe "append_only integration" do
    @tag spec: "specled.append_only.requirement_deleted"
    test "AppendOnly finding flows into BranchCheck.run via Severity.resolve/3", %{root: root} do
      init_git_repo(root)

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{
            "id" => "billing.invoice",
            "statement" => "The system MUST emit an invoice on every charge.",
            "priority" => "must"
          }
        ]
      )

      # Commit only the authored spec source. The prior state is reconstructed
      # from the base tree through BaseView, not from committed state.json.
      commit_all(root, "initial: add billing subject")

      # Now delete the requirement. No authorizing ADR → AppendOnly must fire.
      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: []
      )

      commit_all(root, "remove billing.invoice")

      new_index = SpecLedEx.index(root)
      report = BranchCheck.run(new_index, root, base: "HEAD~1")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "append_only/requirement_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "error"
      assert finding["entity_id"] == "billing.invoice"
      assert finding["message"] =~ "billing.invoice"
      assert finding["message"] =~ "fix:"
      assert report["status"] == "fail"
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "Spec-Drift trailer downgrades an append_only finding to :info", %{root: root} do
      init_git_repo(root)

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{
            "id" => "billing.invoice",
            "statement" => "The system MUST emit an invoice on every charge.",
            "priority" => "must"
          }
        ]
      )

      commit_all(root, "initial")

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: []
      )

      commit_all(root, """
      Retire billing.invoice

      Spec-Drift: append_only/requirement_deleted=info
      """)

      new_index = SpecLedEx.index(root)
      report = BranchCheck.run(new_index, root, base: "HEAD~1")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "append_only/requirement_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "info"
    end

    @tag spec: "specled.append_only.no_baseline"
    test "missing authored spec paths at base yields append_only/no_baseline at :info",
         %{root: root} do
      init_git_repo(root)

      # First commit has no authored spec paths — simulates a base ref
      # predating spec-guardrails adoption.
      write_files(root, %{"README.md" => "# Bootstrap\n"})
      commit_all(root, "initial without spec workspace")

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"},
        requirements: [
          %{
            "id" => "billing.invoice",
            "statement" => "The system MUST emit an invoice on every charge.",
            "priority" => "must"
          }
        ]
      )

      index = SpecLedEx.index(root)
      commit_all(root, "add billing spec")

      report = BranchCheck.run(index, root, base: "HEAD~1")

      findings = Enum.filter(report["findings"], &(&1["code"] == "append_only/no_baseline"))

      assert [finding] = findings
      assert finding["severity"] == "info"
      assert finding["message"] =~ "first-run"
    end

    @tag spec: "specled.append_only.decision_deleted"
    test "base decisions parsed from source make ADR deletion visible", %{root: root} do
      init_git_repo(root)

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"}
      )

      write_decision(root, "billing_split", """
      ---
      id: specled.decision.billing_split
      status: accepted
      date: 2026-07-16
      affects:
        - billing.subject
      change_type: deprecates
      reverses_what: Legacy billing subject.
      ---

      # Billing Split

      ## Context

      Billing changed.

      ## Decision

      Split it.

      ## Consequences

      The decision is durable.
      """)

      commit_all(root, "initial: spec and ADR source")

      File.rm!(Path.join(root, ".spec/decisions/billing_split.md"))
      commit_all(root, "delete ADR")

      index = SpecLedEx.index(root)
      report = BranchCheck.run(index, root, base: "HEAD~1")

      findings = Enum.filter(report["findings"], &(&1["code"] == "append_only/decision_deleted"))

      assert [finding] = findings
      assert finding["severity"] == "error"
      assert finding["entity_id"] == "specled.decision.billing_split"
      assert report["status"] == "fail"
    end
  end

  describe "--base validation" do
    test "--base pointing at a non-existent ref raises a clean ArgumentError", %{root: root} do
      init_git_repo(root)

      write_subject_spec(
        root,
        "billing",
        meta: %{"id" => "billing.subject", "kind" => "module", "status" => "active"}
      )

      commit_all(root, "initial")

      index = SpecLedEx.index(root)

      assert_raise ArgumentError, ~r/does not resolve to a commit/, fn ->
        BranchCheck.run(index, root, base: "definitely-not-a-real-ref")
      end
    end
  end

  describe "self-integration" do
    @tag :integration
    test "BaseView parses HEAD specs against specled_ex's own repo" do
      root = File.cwd!()

      assert {:ok, %{"state" => state}} = SpecLedEx.BaseView.build(root, "HEAD")
      assert is_map(state)
      assert is_map(state["index"])
    end
  end

  # ---------------------------------------------------------------------------
  # File-touch yields to attestation (specled_-3rs.4)
  #
  # These tests exercise the partition introduced in
  # `missing_subject_update_findings/4`: a changed file impacting a subject whose
  # spec.md is not co-changed is downgraded to `:info` when the realization tier
  # produced an attestation for that `(subject, file)` pair, and stays at the
  # strict `:error` default otherwise.
  #
  # The bindings used are real, stable host-module MFAs (e.g.
  # `SpecLedEx.Coverage.default_artifact_path/0`) so the orchestrator's
  # `Binding.resolve_with_source/2` returns a project-relative source path that
  # — once normalized through `Path.relative_to(tmp_root)` — matches the
  # `lib/.../*.ex` form that `ChangeAnalysis` emits for changed files in the
  # tmp repo.
  # ---------------------------------------------------------------------------
  describe "file-touch yields to attestation" do
    alias SpecLedEx.Realization.HashStore

    @tag spec: [
           "specled.branch_guard.file_touch_yields_to_attested_file",
           "specled.branch_guard.status_follows_error_severity"
         ]
    test "attested-clean (file, subject) pair downgrades to :info with binding-naming message",
         %{root: root} do
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      path = "lib/specled_ex/coverage.ex"

      write_subject_spec_with_realized_by(
        root,
        "attest_clean",
        "attest.clean.subject",
        surface: [path],
        realized_by: %{"api_boundary" => [mfa]}
      )

      write_files(root, %{path => "# initial copy of #{path}\n"})

      commit_all(root, "initial: spec + lib file")

      # Comment-only edit: spec.md is NOT co-changed; only the lib file moves.
      write_files(root, %{path => "# initial copy of #{path}\n# comment-only edit\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))

      assert [finding] = findings
      assert finding["severity"] == "info"
      assert finding["file"] == path
      assert finding["message"] =~ "attest.clean.subject"
      assert finding["message"] =~ mfa
      assert finding["message"] =~ "informational only"
      assert report["status"] == "pass"
    end

    @tag spec: "specled.branch_guard.file_touch_yields_to_attested_file"
    test "drift on the binding leaves the file-touch finding at strict :error", %{root: root} do
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      path = "lib/specled_ex/coverage.ex"

      # Seed a deliberately wrong hash so this run produces a
      # `branch_guard_realization_drift` finding for the MFA. Drift removes the
      # `(subject, file)` pair from the attestation map — the file-touch guard
      # must fall back to the strict default.
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      write_subject_spec_with_realized_by(
        root,
        "attest_drift",
        "attest.drift.subject",
        surface: [path],
        realized_by: %{"api_boundary" => [mfa]}
      )

      write_files(root, %{path => "# initial copy of #{path}\n"})

      commit_all(root, "initial: spec + lib file")

      write_files(root, %{path => "# initial copy of #{path}\n# comment-only edit\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD", commit_realization_hashes?: false)

      file_findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))

      assert [finding] = file_findings
      assert finding["severity"] == "error"
      assert finding["message"] =~ "subject specs that were not updated"
      assert finding["message"] =~ "attest.drift.subject"
      refute finding["message"] =~ "informational only"

      assert Enum.any?(report["findings"], fn f ->
               f["code"] == "branch_guard_realization_drift" and Map.get(f, "mfa") == mfa
             end)
    end

    @tag spec: "specled.branch_guard.file_touch_yields_to_attested_file"
    test "surface-only file with no resolving binding stays strict :error", %{root: root} do
      # The subject has a `realized_by` binding naming a different file (not the
      # one the author touched). The touched file is in the surface but no
      # binding resolves to it, so no attestation entry exists for the (subject,
      # file) pair — the strict default wins.
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      bound_path = "lib/specled_ex/coverage.ex"
      untouched_helper = "lib/specled_ex/internal_helpers.ex"

      write_subject_spec_with_realized_by(
        root,
        "surface_only",
        "surface.only.subject",
        # Surface includes the helper directory glob so an edit to the helper
        # impacts the subject; but the only realized_by binding resolves to the
        # other file, not the helper.
        surface: [bound_path, untouched_helper],
        realized_by: %{"api_boundary" => [mfa]}
      )

      write_files(root, %{
        bound_path => "# stable copy\n",
        untouched_helper => "# helper v1\n"
      })

      commit_all(root, "initial")

      # Edit the helper that no binding names.
      write_files(root, %{untouched_helper => "# helper v1\n# edit\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))

      assert [finding] = findings
      assert finding["severity"] == "error"
      assert finding["file"] == untouched_helper
      assert finding["message"] =~ "subject specs that were not updated"
    end

    @tag spec: "specled.branch_guard.file_touch_per_subject_independence"
    test "multi-subject partial attestation produces independent info + error findings",
         %{root: root} do
      # `lib/specled_ex/coverage.ex` is impacted by two subjects:
      #   - subj_a — has a clean realized_by binding naming the file (attested)
      #   - subj_b — has no realized_by (no attestation, strict)
      # One run must emit both findings: one info (subj_a), one error (subj_b).
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      path = "lib/specled_ex/coverage.ex"

      write_subject_spec_with_realized_by(
        root,
        "multi_a",
        "multi.subj_a",
        surface: [path],
        realized_by: %{"api_boundary" => [mfa]}
      )

      write_subject_spec_with_realized_by(
        root,
        "multi_b",
        "multi.subj_b",
        surface: [path],
        realized_by: %{}
      )

      write_files(root, %{path => "# initial\n"})

      commit_all(root, "initial: two specs sharing one surface")

      write_files(root, %{path => "# initial\n# touch\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))
        |> Enum.sort_by(& &1["severity"])

      assert length(findings) == 2

      info = Enum.find(findings, &(&1["severity"] == "info"))
      error = Enum.find(findings, &(&1["severity"] == "error"))

      assert info, "expected an info finding for the attested subject; got #{inspect(findings)}"
      assert info["message"] =~ "multi.subj_a"
      assert info["message"] =~ mfa
      assert info["message"] =~ "informational only"

      assert error, "expected an error finding for the unattested subject"
      assert error["message"] =~ "multi.subj_b"
      assert error["message"] =~ "subject specs that were not updated"
      refute error["message"] =~ "multi.subj_a"
    end

    @tag spec: "specled.branch_guard.file_touch_severity_config_wins"
    test "project severity pin to :error overrides the attested :info default", %{root: root} do
      # Same setup as the attested-clean test, but the project pins
      # branch_guard_missing_subject_update to :error in branch_guard.severities.
      # The pin must win over the attested default — the finding fires at
      # :error regardless of attestation. The downgrade flows through
      # Severity.resolve/3 as the `default` argument, so a config override
      # for the same code is checked first.
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      path = "lib/specled_ex/coverage.ex"

      write_files(root, %{
        ".spec/config.yml" => """
        branch_guard:
          severities:
            branch_guard_missing_subject_update: error
        """
      })

      write_subject_spec_with_realized_by(
        root,
        "severity_pin",
        "severity.pin.subject",
        surface: [path],
        realized_by: %{"api_boundary" => [mfa]}
      )

      write_files(root, %{path => "# initial\n"})

      commit_all(root, "initial")

      write_files(root, %{path => "# initial\n# touch\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))

      assert [finding] = findings
      assert finding["severity"] == "error"
    end

    @tag spec: "specled.branch_guard.file_touch_severity_config_wins"
    test ":off in branch_guard.severities absorbs both attested and unattested branches",
         %{root: root} do
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      path = "lib/specled_ex/coverage.ex"

      write_files(root, %{
        ".spec/config.yml" => """
        branch_guard:
          severities:
            branch_guard_missing_subject_update: off
        """
      })

      write_subject_spec_with_realized_by(
        root,
        "severity_off",
        "severity.off.subject",
        surface: [path],
        realized_by: %{"api_boundary" => [mfa]}
      )

      write_files(root, %{path => "# initial\n"})

      commit_all(root, "initial")

      write_files(root, %{path => "# initial\n# touch\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      refute Enum.any?(
               report["findings"],
               &(&1["code"] == "branch_guard_missing_subject_update")
             )
    end

    @tag spec: "specled.branch_guard.file_touch_tagged_tests_attested"
    test "tagged_tests covers expand attestation to test files for the attested requirement",
         %{root: root} do
      # A requirement-level realized_by attests clean for the production-code
      # file. A `kind: tagged_tests` verification on the subject covers that
      # requirement. The tag map registers a test file under that requirement.
      # The orchestrator extends the attestation map to the test file (carrying
      # the same MFA list as the production attestation). A comment-only edit to
      # that test file must downgrade the file-touch finding to :info.
      init_git_repo(root)

      mfa = "SpecLedEx.Coverage.default_artifact_path/0"
      req_id = "tt.tagged.req"
      test_path = "test/coverage_test.exs"

      write_files(root, %{
        ".spec/config.yml" => """
        test_tags:
          enabled: true
          paths:
            - test
        """,
        ".spec/specs/tt_tagged.spec.md" => """
        # Tt Tagged

        ```spec-meta
        {
          "id": "tt.tagged.subject",
          "kind": "module",
          "status": "active",
          "surface": ["#{test_path}"]
        }
        ```

        ```spec-requirements
        [
          {
            "id": "#{req_id}",
            "statement": "Covered by tagged tests",
            "priority": "must",
            "realized_by": {"api_boundary": ["#{mfa}"]}
          }
        ]
        ```

        ```spec-verification
        [
          {
            "kind": "tagged_tests",
            "execute": true,
            "covers": ["#{req_id}"]
          }
        ]
        ```
        """,
        test_path => """
        defmodule CoverageTest do
          use ExUnit.Case

          @tag spec: "#{req_id}"
          test "covers #{req_id}" do
            assert true
          end
        end
        """
      })

      commit_all(root, "initial: tagged-tests subject + test file")

      # Comment-only edit on the test file; spec.md not co-changed.
      write_files(root, %{
        test_path => """
        defmodule CoverageTest do
          use ExUnit.Case

          # comment-only edit
          @tag spec: "#{req_id}"
          test "covers #{req_id}" do
            assert true
          end
        end
        """
      })

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD")

      findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))
        |> Enum.filter(&(&1["file"] == test_path))

      assert [finding] = findings,
             "expected exactly one missing_subject_update finding for the test file; got #{inspect(findings)}"

      assert finding["severity"] == "info"
      assert finding["message"] =~ "tt.tagged.subject"
      assert finding["message"] =~ mfa
      assert finding["message"] =~ "informational only"
    end

    @tag spec: "specled.branch_guard.file_touch_detector_failure_strict"
    test "binding whose resolver returns no source path falls back to strict :error",
         %{root: root} do
      # The realization tier returns no source path for the binding (the MFA is
      # bogus and the BEAM does not load → dangling). The orchestrator emits
      # `branch_guard_dangling_binding` and the (subject, file) pair is absent
      # from the attestation map. The file-touch guard must fire at :error.
      init_git_repo(root)

      bogus_mfa = "SpecLedEx.Truly.Nonexistent.gone/0"
      path = "lib/specled_ex/coverage.ex"

      write_subject_spec_with_realized_by(
        root,
        "detector_fail",
        "detector.fail.subject",
        surface: [path],
        realized_by: %{"api_boundary" => [bogus_mfa]}
      )

      write_files(root, %{path => "# initial\n"})

      commit_all(root, "initial")

      write_files(root, %{path => "# initial\n# touch\n"})

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD", commit_realization_hashes?: false)

      file_findings =
        Enum.filter(report["findings"], &(&1["code"] == "branch_guard_missing_subject_update"))

      assert [finding] = file_findings
      assert finding["severity"] == "error"
      assert finding["message"] =~ "detector.fail.subject"
      refute finding["message"] =~ "informational only"

      assert Enum.any?(report["findings"], fn f ->
               f["code"] == "branch_guard_dangling_binding" and Map.get(f, "mfa") == bogus_mfa
             end)
    end
  end

  describe "branch_guard_missing_decision_update message" do
    @tag spec: "specled.branch_guard.missing_decision_fix_block"
    test "ends with a fix block naming the ADR and trailer arms", %{root: root} do
      init_git_repo(root)

      write_files(root, %{
        "lib/a.ex" => "defmodule A do\nend\n",
        "lib/b.ex" => "defmodule B do\nend\n"
      })

      write_subject_spec(
        root,
        "a",
        meta: %{
          "id" => "a.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/a.ex"]
        }
      )

      write_subject_spec(
        root,
        "b",
        meta: %{
          "id" => "b.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/b.ex"]
        }
      )

      commit_all(root, "initial")

      write_files(root, %{
        "lib/a.ex" => "defmodule A do\n  def run, do: :ok\nend\n",
        "lib/b.ex" => "defmodule B do\n  def run, do: :ok\nend\n"
      })

      # Touch both subject specs so only the decision co-change is missing.
      for name <- ["a", "b"] do
        path = Path.join(root, ".spec/specs/#{name}.spec.md")
        File.write!(path, File.read!(path) <> "\n")
      end

      index = Index.build(root)
      report = BranchCheck.run(index, root, base: "HEAD", commit_realization_hashes?: false)

      assert [finding] =
               Enum.filter(
                 report["findings"],
                 &(&1["code"] == "branch_guard_missing_decision_update")
               )

      assert finding["message"] =~
               "```\nfix: if this branch changes durable cross-cutting policy, add or revise an ADR (`mix spec.decision.new <id> --title \"...\"`); if it does not, record `Spec-Drift: branch_guard_missing_decision_update=info` as a git trailer on a commit in this range, with a one-line reason in the commit body.\n```"

      assert String.ends_with?(String.trim_trailing(finding["message"]), "```")
    end
  end

  # Helper for tests in the file-touch-yields-to-attestation describe block.
  # `write_subject_spec/3` is geared toward the existing tests' meta layout
  # (id/kind/status only); these tests need realized_by and surface inline.
  defp write_subject_spec_with_realized_by(root, name, subject_id, opts) do
    surface = Keyword.get(opts, :surface, [])
    realized_by = Keyword.get(opts, :realized_by, %{})

    meta =
      %{
        "id" => subject_id,
        "kind" => "module",
        "status" => "active",
        "surface" => surface
      }
      |> maybe_put_realized_by(realized_by)

    write_subject_spec(root, name, meta: meta)
  end

  defp maybe_put_realized_by(meta, rb) when map_size(rb) == 0, do: meta
  defp maybe_put_realized_by(meta, rb), do: Map.put(meta, "realized_by", rb)
end
