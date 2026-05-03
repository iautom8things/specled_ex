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
