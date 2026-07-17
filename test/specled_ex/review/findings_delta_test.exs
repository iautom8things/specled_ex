defmodule SpecLedEx.Review.FindingsDeltaTest do
  use SpecLedEx.Case

  alias SpecLedEx.Review
  alias SpecLedEx.Review.FindingsDelta
  alias SpecLedEx.Evidence.{Entry, Store}

  # A head-side finding carries the live verifier shape (subject_id / severity).
  defp head_finding(code, entity, file, message, severity \\ "warning") do
    %{
      "code" => code,
      "subject_id" => entity,
      "file" => file,
      "message" => message,
      "severity" => severity
    }
  end

  defp record_base_evidence(root, findings) do
    tree_hash = root |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    entry =
      Entry.build(tree_hash, %{"findings" => findings},
        run_at: "2026-07-16T12:00:00.000000Z",
        run_id: String.duplicate("a", 32),
        specled_version: "test"
      )

    assert :ok = Store.record(root, entry)
  end

  describe "FindingsDelta.classify/3 differential classification" do
    @tag spec: "specled.spec_review.findings_delta"
    test "classifies the head finding absent at base as introduced and the shared one as pre_existing",
         %{root: root} do
      init_git_repo(root)

      f1 = "verification_target_missing_reference"
      f1_file = ".spec/specs/auth.spec.md"
      f1_msg = "Verification target missing reference"

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")
      record_base_evidence(root, [head_finding(f1, "auth.subject", f1_file, f1_msg)])

      head = [
        head_finding(f1, "auth.subject", f1_file, f1_msg),
        head_finding("overlap_subject", "auth.subject", f1_file, "brand new finding", "error")
      ]

      result = FindingsDelta.classify(root, "main", head)

      assert result.delta_available? == true

      assert [introduced] = result.introduced
      assert introduced["message"] == "brand new finding"

      assert [pre_existing] = result.pre_existing
      assert pre_existing["message"] == f1_msg

      assert result.resolved == []

      assert result.change_verdict.differential? == true
      assert result.change_verdict.clean? == false
      assert result.change_verdict.introduced_count == 1
      assert result.change_verdict.by_severity == %{"error" => 1}
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "matches identity across the normalized base shape and the live head shape", %{
      root: root
    } do
      init_git_repo(root)

      code = "verification_target_missing_reference"
      file = ".spec/specs/auth.spec.md"
      msg = "identical finding text"

      # Base is normalized (entity_id/level); head is live (subject_id/severity).
      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")
      record_base_evidence(root, [head_finding(code, "auth.subject", file, msg)])

      result =
        FindingsDelta.classify(root, "main", [head_finding(code, "auth.subject", file, msg)])

      assert result.pre_existing != []
      assert result.introduced == []
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "classifies a base finding absent at head as resolved", %{root: root} do
      init_git_repo(root)

      code = "overlap_subject"
      file = ".spec/specs/auth.spec.md"
      msg = "was here at base only"

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")
      record_base_evidence(root, [head_finding(code, "auth.subject", file, msg)])

      result = FindingsDelta.classify(root, "main", [])

      assert [resolved] = result.resolved
      assert resolved["message"] == msg
      assert result.introduced == []
      assert result.change_verdict.clean? == true
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "an empty base findings set makes every head finding introduced", %{root: root} do
      init_git_repo(root)
      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")
      record_base_evidence(root, [])

      head = [head_finding("overlap_subject", "auth.subject", ".spec/specs/auth.spec.md", "new")]
      result = FindingsDelta.classify(root, "main", head)

      assert result.delta_available? == true
      assert length(result.introduced) == 1
      assert result.pre_existing == []
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "exposes parser-upgrade transients as resolved base kinds and introduced head kinds", %{
      root: root
    } do
      init_git_repo(root)
      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")

      record_base_evidence(root, [
        head_finding("old_parser_kind", "auth.subject", "lib/auth.ex", "base-only kind")
      ])

      result =
        FindingsDelta.classify(root, "main", [
          head_finding("new_parser_kind", "auth.subject", "lib/auth.ex", "head-only kind")
        ])

      assert Enum.map(result.resolved, & &1["code"]) == ["old_parser_kind"]
      assert Enum.map(result.introduced, & &1["code"]) == ["new_parser_kind"]
    end
  end

  describe "FindingsDelta.classify/3 non-differential fallback" do
    @tag spec: "specled.spec_review.findings_delta"
    test "falls back to non-differential when the base tree has no evidence entry", %{
      root: root
    } do
      init_git_repo(root)
      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")

      head = [head_finding("overlap_subject", "auth.subject", "lib/auth.ex", "some finding")]
      result = FindingsDelta.classify(root, "main", head)

      assert result.delta_available? == false
      assert result.base_reason == :base_evidence_absent
      # No finding is presented as introduced when base attribution is missing.
      assert result.introduced == []
      assert result.pre_existing == []
      assert result.resolved == []
      assert result.change_verdict.differential? == false
      assert result.change_verdict.clean? == nil
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "distinguishes an unresolvable base tree from absent evidence", %{root: root} do
      init_git_repo(root)
      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "base content")

      head = [head_finding("overlap_subject", "auth.subject", "lib/auth.ex", "some finding")]
      result = FindingsDelta.classify(root, "missing-base-ref", head)

      assert result.delta_available? == false
      assert result.base_reason == :base_tree_unresolvable
      assert result.introduced == []
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "falls back when the base ref is nil", %{root: root} do
      result = FindingsDelta.classify(root, nil, [])

      assert result.delta_available? == false
      assert result.base_reason == :base_tree_unresolvable
    end
  end

  describe "build_view/3 findings delta integration" do
    @tag spec: "specled.spec_review.findings_delta"
    test "attaches a differential delta and marks a head-only finding as introduced", %{
      root: root
    } do
      setup_repo(root, "auth_subject", "Auth.")
      # Record base evidence with no findings so the head-side synthetic
      # no_realized_by finding classifies as introduced.
      record_base_evidence(root, [])
      change_subject_file(root)

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "HEAD")

      assert view.findings_delta.delta_available? == true

      assert Enum.any?(view.findings_delta.introduced, &(&1["reason"] == "no_realized_by"))
      assert view.findings_delta.change_verdict.clean? == false
      assert view.findings_delta.change_verdict.introduced_count >= 1
    end

    @tag spec: "specled.spec_review.findings_delta"
    test "falls back to non-differential when no base evidence is stored", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root)

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      # The seed subject declares no realized_by, so a head finding exists.
      assert view.all_findings != []
      assert view.findings_delta.delta_available? == false
      # It must not be presented as introduced by the change.
      assert view.findings_delta.introduced == []
    end
  end

  describe "Review.change_kind/2" do
    test "spec edit dominates" do
      assert Review.change_kind(true, false) == :spec_edited
      assert Review.change_kind(true, true) == :spec_edited
    end

    test "code changes without a spec edit are code_only" do
      assert Review.change_kind(false, true) == :code_only
    end

    test "no file of its own changed is impacted_only" do
      assert Review.change_kind(false, false) == :impacted_only
    end
  end

  describe "build_view/3 queue grouping" do
    test "a code-only change carries the code_only kind and a populated diffstat", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")
      change_subject_file(root)

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert [subject] = view.affected_subjects
      assert subject.change_kind == :code_only
      assert subject.diffstat.adds >= 1
    end

    test "a spec edit carries the spec_edited kind", %{root: root} do
      setup_repo(root, "auth_subject", "Auth.")

      write_subject_spec(
        root,
        "auth_subject",
        meta: %{
          "id" => "auth.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Auth, revised.",
          "surface" => ["lib/auth.ex"]
        }
      )

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert [subject] = view.affected_subjects
      assert subject.change_kind == :spec_edited
    end

    test "queue_subjects groups spec-edited ahead of code-only and orders by size", %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "alpha",
        meta: %{
          "id" => "alpha.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Alpha.",
          "surface" => ["lib/alpha.ex"]
        }
      )

      write_subject_spec(root, "beta",
        meta: %{
          "id" => "beta.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Beta.",
          "surface" => ["lib/beta.ex"]
        }
      )

      write_files(root, %{
        "lib/alpha.ex" => "defmodule Alpha do\nend\n",
        "lib/beta.ex" => "defmodule Beta do\nend\n"
      })

      commit_all(root, "initial")

      # alpha: spec edit. beta: code-only change.
      write_subject_spec(root, "alpha",
        meta: %{
          "id" => "alpha.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Alpha, revised.",
          "surface" => ["lib/alpha.ex"]
        }
      )

      write_files(root, %{"lib/beta.ex" => "defmodule Beta do\n  def go, do: :ok\nend\n"})

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      kinds = Enum.map(view.queue_subjects, & &1.change_kind)
      assert kinds == [:spec_edited, :code_only]
      assert Enum.map(view.queue_subjects, & &1.id) == ["alpha.subject", "beta.subject"]
    end

    test "queue_subjects orders same-kind subjects by change size descending", %{root: root} do
      init_git_repo(root)

      for name <- ~w(small big) do
        write_subject_spec(root, name,
          meta: %{
            "id" => "#{name}.subject",
            "kind" => "module",
            "status" => "active",
            "summary" => "#{name}.",
            "surface" => ["lib/#{name}.ex"]
          }
        )
      end

      write_files(root, %{
        "lib/small.ex" => "defmodule Small do\nend\n",
        "lib/big.ex" => "defmodule Big do\nend\n"
      })

      commit_all(root, "initial")

      write_files(root, %{
        "lib/small.ex" => "defmodule Small do\n  def a, do: :ok\nend\n",
        "lib/big.ex" =>
          "defmodule Big do\n  def a, do: :ok\n  def b, do: :ok\n  def c, do: :ok\nend\n"
      })

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      assert Enum.map(view.queue_subjects, & &1.id) == ["big.subject", "small.subject"]
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

  defp change_subject_file(root) do
    write_files(root, %{"lib/auth.ex" => "defmodule Auth do\n  def login, do: :ok\nend\n"})
  end
end
