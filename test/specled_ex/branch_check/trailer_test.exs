defmodule SpecLedEx.BranchCheck.TrailerTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.spec_drift_trailer.parse_unknown_token_warns", "specled.spec_drift_trailer.parse_vocabulary", "specled.spec_drift_trailer.scans_base_to_head", "specled.spec_drift_trailer.self_report_documented"]

  alias SpecLedEx.BranchCheck.Severity
  alias SpecLedEx.BranchCheck.Trailer

  describe "parse/1 preset vocabulary" do
    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "refactor maps to realization_drift :info" do
      assert %{
               overrides: %{"branch_guard_realization_drift" => :info},
               warnings: []
             } = Trailer.parse("Some subject\n\nSpec-Drift: refactor\n")
    end

    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "docs_only and test_only each map their own preset" do
      assert %{overrides: overrides, warnings: []} =
               Trailer.parse("""
               whatever

               Spec-Drift: docs_only
               Spec-Drift: test_only
               """)

      assert overrides == %{
               "branch_guard_unmapped_change" => :info,
               "branch_guard_missing_subject_update" => :info
             }
    end

    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "explicit code=severity pair is accepted" do
      assert %{
               overrides: %{"branch_guard_realization_drift" => :error},
               warnings: []
             } = Trailer.parse("Spec-Drift: branch_guard_realization_drift=error")
    end

    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "multiple comma-separated tokens on one line" do
      assert %{overrides: overrides, warnings: []} =
               Trailer.parse("Spec-Drift: refactor, docs_only")

      assert overrides == %{
               "branch_guard_realization_drift" => :info,
               "branch_guard_unmapped_change" => :info
             }
    end

    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "unknown tokens produce a warning and no override" do
      assert %{overrides: %{}, warnings: warnings} =
               Trailer.parse("Spec-Drift: lolwut")

      assert [message] = warnings
      assert message =~ "lolwut"
    end

    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "unknown severity in pair produces a warning" do
      assert %{overrides: %{}, warnings: warnings} =
               Trailer.parse("Spec-Drift: some_code=panic")

      assert [message] = warnings
      assert message =~ "some_code=panic"
    end

    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "body without any Spec-Drift lines yields empty result" do
      assert %{overrides: %{}, warnings: []} = Trailer.parse("just a normal commit")
    end
  end

  describe "read/2 scans base..HEAD (not HEAD-only)" do
    @tag spec: "specled.spec_drift_trailer.scans_base_to_head"
    @tag spec: "specled.spec_drift_trailer.parse_vocabulary"
    test "trailer on an earlier commit applies to the branch (refactor_downgrades_realization_drift)",
         %{root: root} do
      init_git_repo(root)
      write_files(root, %{"README.md" => "init\n"})
      commit_all(root, "initial")

      write_files(root, %{"file.ex" => "defmodule A do\nend\n"})

      git!(root, ["add", "."])

      git!(root, [
        "commit",
        "-m",
        """
        Refactor A module

        Spec-Drift: refactor
        """
      ])

      write_files(root, %{"file.ex" => "defmodule A do\n  def hi, do: :hi\nend\n"})
      commit_all(root, "tip commit without trailer")

      result = Trailer.read(root, "main~2")
      assert Map.has_key?(result.overrides, "branch_guard_realization_drift")
      assert result.overrides["branch_guard_realization_drift"] == :info

      assert Severity.resolve(
               "branch_guard_realization_drift",
               [trailer_override: result.overrides],
               :warning
             ) == :info
    end

    @tag spec: "specled.spec_drift_trailer.scans_base_to_head"
    test "empty range yields empty overrides", %{root: root} do
      init_git_repo(root)
      write_files(root, %{"README.md" => "init\n"})
      commit_all(root, "initial")

      assert %{overrides: %{}, warnings: []} = Trailer.read(root, "HEAD")
    end

    @tag spec: "specled.spec_drift_trailer.scans_base_to_head"
    test "git failure returns empty result", %{root: root} do
      assert %{overrides: %{}, warnings: []} = Trailer.read(root, "no-such-ref")
    end
  end

  describe "self-report documentation" do
    @tag spec: "specled.spec_drift_trailer.self_report_documented"
    test "@moduledoc names the self-report property" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Trailer)
      assert moduledoc =~ "self-report"
      assert moduledoc =~ "small-team"
    end
  end
end
