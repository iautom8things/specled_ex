defmodule SpecLedEx.ReviewTest do
  use SpecLedEx.Case

  alias SpecLedEx.Review

  describe "build_view/3 view-model shape" do
    @tag spec: "specled.spec_review.spec_first_navigation"
    test "puts each affected subject's prose statement at the headline of the card", %{root: root} do
      setup_repo(root, "auth_subject", "Authentication boundary protects credentials end-to-end.")

      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert [subject] = Enum.filter(view.affected_subjects, &(&1.id == "auth.subject"))
      assert subject.statement == "Authentication boundary protects credentials end-to-end."
      assert subject.title == "Auth Subject"
    end

    @tag spec: "specled.spec_review.misc_panel"
    test "puts unmapped changed files into unmapped_changes rather than dropping them", %{
      root: root
    } do
      setup_repo(root, "auth_subject", "Auth subject.")

      write_files(root, %{"unowned/random.txt" => "hello\n"})
      commit_all(root, "add untouched random file")

      write_files(root, %{"unowned/random.txt" => "hello world\n"})

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert Enum.any?(view.unmapped_changes, &(&1.file == "unowned/random.txt"))
    end

    @tag spec: "specled.spec_review.triage_panel"
    test "marks triage as clean when there are no findings, no unmapped changes, and no affected subjects",
         %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert view.triage.clean? == true
      assert view.triage.findings_count == 0
      assert view.triage.has_unmapped_changes? == false
    end

    @tag spec: "specled.spec_review.triage_panel"
    test "summarizes findings with severity counts and surfaces them in all_findings", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      add_unknown_decision_reference(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert view.triage.findings_count > 0
      assert view.triage.by_severity != %{}
      assert length(view.all_findings) == view.triage.findings_count
    end

    @tag spec: "specled.spec_review.diff_against_base"
    test "uses the explicit --base option when provided", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert view.meta.base_ref == "main"
    end
  end

  describe "FileDiff.for_files/3" do
    test "returns an empty map when no paths are passed", %{root: root} do
      assert SpecLedEx.Review.FileDiff.for_files(root, "main", []) == %{}
    end

    test "parses additions and deletions for a tracked file", %{root: root} do
      init_git_repo(root)
      write_files(root, %{"foo.txt" => "alpha\nbeta\n"})
      commit_all(root, "initial")

      write_files(root, %{"foo.txt" => "alpha\ngamma\n"})

      result = SpecLedEx.Review.FileDiff.for_files(root, "main", ["foo.txt"])

      kinds = result["foo.txt"] |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert :hunk_header in kinds
      assert :add in kinds
      assert :del in kinds
    end

    test "synthesizes additions for untracked files", %{root: root} do
      init_git_repo(root)
      commit_initial_empty(root)

      write_files(root, %{"new.txt" => "fresh content\n"})

      result = SpecLedEx.Review.FileDiff.for_files(root, "main", ["new.txt"])
      kinds = result["new.txt"] |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert :file_header in kinds
      assert :add in kinds
    end
  end

  describe "Html.render_subject_binding_health/2" do
    alias SpecLedEx.Review.Html

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "renders the no-realized_by chip when bindings is empty" do
      html = IO.iodata_to_binary(Html.render_subject_binding_health(%{}, []))

      assert html =~ "0 bindings (no realized_by declared)"
      assert html =~ "badge-binding-empty"
      refute html =~ "all valid"
      refute html =~ "dangling"
    end

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "renders the no-realized_by chip when bindings is nil" do
      html = IO.iodata_to_binary(Html.render_subject_binding_health(nil, []))

      assert html =~ "0 bindings (no realized_by declared)"
      assert html =~ "badge-binding-empty"
    end

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "renders the all-valid chip when bindings exist and no dangling findings are present" do
      bindings = %{
        "api_boundary" => ["MyApp.API.do_thing/1"],
        "implementation" => ["MyApp.Impl"]
      }

      html = IO.iodata_to_binary(Html.render_subject_binding_health(bindings, []))

      assert html =~ "2 bindings, all valid"
      assert html =~ "badge-binding-valid"
      refute html =~ "dangling"
    end

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "uses singular 'binding' when there is exactly one" do
      bindings = %{"api_boundary" => ["MyApp.API.do_thing/1"]}

      html = IO.iodata_to_binary(Html.render_subject_binding_health(bindings, []))

      assert html =~ "1 binding, all valid"
      refute html =~ "1 bindings"
    end

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "renders the dangling chip with the dangling count when dangling-binding findings exist" do
      bindings = %{
        "api_boundary" => ["MyApp.API.do_thing/1", "MyApp.API.other/0"],
        "implementation" => ["MyApp.Impl"]
      }

      findings = [
        %{"code" => "branch_guard_dangling_binding", "severity" => "error"},
        %{"code" => "branch_guard_dangling_binding", "severity" => "error"},
        %{"code" => "some_other_finding", "severity" => "warning"}
      ]

      html = IO.iodata_to_binary(Html.render_subject_binding_health(bindings, findings))

      assert html =~ "3 bindings, 2 dangling"
      assert html =~ "badge-binding-dangling"
      refute html =~ "all valid"
    end

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "ignores findings whose code is not branch_guard_dangling_binding" do
      bindings = %{"api_boundary" => ["MyApp.API.do_thing/1"]}

      findings = [
        %{"code" => "branch_guard_realization_drift", "severity" => "error"},
        %{"code" => "overlap_subject", "severity" => "warning"}
      ]

      html = IO.iodata_to_binary(Html.render_subject_binding_health(bindings, findings))

      assert html =~ "1 binding, all valid"
      refute html =~ "dangling"
    end

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "treats a single non-list MFA value as one binding (List.wrap parity with bindings dl)" do
      bindings = %{"implementation" => "MyApp.Impl"}

      html = IO.iodata_to_binary(Html.render_subject_binding_health(bindings, []))

      assert html =~ "1 binding, all valid"
    end
  end

  describe "subject card binding-health badge integration" do
    alias SpecLedEx.Review.Html

    @tag spec: "specled.spec_review.inline_finding_badges"
    test "rendered HTML carries a binding-health badge on each subject card", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")
      html = view |> Html.render() |> IO.iodata_to_binary()

      assert html =~ "badge-binding-health"
      # The seed subject declares no realized_by, so it should land in the
      # "no realized_by declared" state.
      assert html =~ "0 bindings (no realized_by declared)"
    end
  end

  # covers: specled.spec_review.coverage_tab_bind_closure
  describe "Coverage tab bind-closure integration" do
    alias SpecLedEx.Review.Html

    test "build_view attaches closure_reach to each affected subject", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)

      view =
        Review.build_view(index, root,
          base: "main",
          closure_reach_opts: [
            tracer_edges: %{},
            coverage_records: :no_coverage_artifact
          ]
        )

      assert [subject] = view.affected_subjects
      assert is_map(subject.closure_reach)
      assert Map.has_key?(subject.closure_reach, :status)
      assert Map.has_key?(subject.closure_reach, :by_requirement)
    end

    test "rendered Coverage tab degrades to a 'coverage artifact unavailable' banner when records are missing",
         %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)

      view =
        Review.build_view(index, root,
          base: "main",
          closure_reach_opts: [
            # An empty edges map degrades to :no_tracer_manifest first; pass
            # a non-empty map so the coverage status path is exercised.
            tracer_edges: %{{Auth, :login, 0} => []},
            coverage_records: :no_coverage_artifact
          ]
        )

      html = view |> Html.render() |> IO.iodata_to_binary()

      assert html =~ "Coverage artifact unavailable"
    end

    test "rendered Coverage tab degrades to a 'binding closure unavailable' banner when tracer manifest is missing",
         %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)

      view =
        Review.build_view(index, root,
          base: "main",
          closure_reach_opts: [
            tracer_edges: %{},
            coverage_records: []
          ]
        )

      html = view |> Html.render() |> IO.iodata_to_binary()

      assert html =~ "Binding closure unavailable"
    end
  end

  describe "no_realized_by detector_unavailable synthesis" do
    alias SpecLedEx.Review.Html

    @tag spec: "specled.spec_review.no_realized_by_degrades_spec_to_code"
    test "synthesizes a detector_unavailable finding for affected subjects with no realized_by",
         %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert [synth] =
               view.all_findings
               |> Enum.filter(fn f ->
                 f["code"] == "detector_unavailable" and f["reason"] == "no_realized_by"
               end)

      assert synth["subject_id"] == "auth.subject"
      assert synth["severity"] == "info"

      assert synth["message"] =~ "no `realized_by`" or synth["message"] =~ "no realized_by"

      # The triage's leg aggregation must place the synthesized reason on
      # SPEC ↔ CODE so the diagram surfaces the leg as :degraded.
      assert get_in(view.triage.detector_unavailable_by_leg, [:spec_to_code, "no_realized_by"]) ==
               1
    end

    @tag spec: "specled.spec_review.no_realized_by_degrades_spec_to_code"
    test "does not synthesize a finding when the subject declares any non-empty realized_by tier",
         %{root: root} do
      setup_repo_with_realized_by(root, "auth_subject", "Auth.", %{
        "api_boundary" => ["MyApp.API.do_thing/1"]
      })

      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      synth =
        Enum.filter(view.all_findings, fn f ->
          f["code"] == "detector_unavailable" and f["reason"] == "no_realized_by"
        end)

      assert synth == []

      assert get_in(view.triage.detector_unavailable_by_leg, [:spec_to_code, "no_realized_by"]) ==
               nil
    end

    @tag spec: "specled.spec_review.no_realized_by_degrades_spec_to_code"
    test "does not synthesize a finding when only a requirement declares realized_by",
         %{root: root} do
      init_git_repo(root)

      write_subject_spec(
        root,
        "auth_subject",
        meta: %{
          "id" => "auth.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Auth.",
          "surface" => ["lib/auth.ex"]
        },
        requirements: [
          %{
            "id" => "auth.subject.do_thing",
            "statement" => "Auth.do_thing/1 logs the caller.",
            "priority" => "must",
            "stability" => "evolving",
            "realized_by" => %{"api_boundary" => ["MyApp.API.do_thing/1"]}
          }
        ]
      )

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "initial")

      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      synth =
        Enum.filter(view.all_findings, fn f ->
          f["code"] == "detector_unavailable" and f["reason"] == "no_realized_by"
        end)

      assert synth == [],
             "expected no synthesized finding when a requirement declares realized_by"
    end

    @tag spec: "specled.spec_review.no_realized_by_degrades_spec_to_code"
    test "rendered HTML degrades the realized_by leg and surfaces the partial-report banner with the no_realized_by reason",
         %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root, "auth_subject")

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")
      html = view |> Html.render() |> IO.iodata_to_binary()

      # Diagram leg is :degraded with a `?` glyph.
      assert html =~ "sync-edge sync-edge-degraded"

      # Partial-report banner enumerates `no_realized_by` as a reason.
      assert html =~ "sync-degraded-banner"
      assert html =~ "no_realized_by"
      assert html =~ "Partial report"
    end
  end

  # ----------------------------------------------------------------------
  # helpers
  # ----------------------------------------------------------------------

  defp setup_repo(root, name, statement) do
    init_git_repo(root)

    write_subject_spec(
      root,
      name,
      meta: %{
        "id" => "auth.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => statement,
        "surface" => ["lib/auth.ex"]
      }
    )

    write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
    commit_all(root, "initial")
  end

  defp setup_repo_with_realized_by(root, name, statement, realized_by) do
    init_git_repo(root)

    write_subject_spec(
      root,
      name,
      meta: %{
        "id" => "auth.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => statement,
        "surface" => ["lib/auth.ex"],
        "realized_by" => realized_by
      }
    )

    write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
    commit_all(root, "initial")
  end

  defp change_subject_file(root, _name) do
    write_files(root, %{"lib/auth.ex" => "defmodule Auth do\n  def login, do: :ok\nend\n"})
  end

  defp add_unknown_decision_reference(root, name) do
    write_subject_spec(
      root,
      name,
      meta: %{
        "id" => "auth.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => "Auth.",
        "surface" => ["lib/auth.ex"],
        "decisions" => ["does.not.exist"]
      }
    )
  end

  defp commit_initial_empty(root) do
    write_files(root, %{".gitkeep" => ""})
    commit_all(root, "initial")
  end
end
