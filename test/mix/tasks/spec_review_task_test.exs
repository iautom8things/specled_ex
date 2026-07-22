defmodule Mix.Tasks.SpecReviewTaskTest do
  use SpecLedEx.Case

  alias SpecLedEx.Evidence.{Entry, Store}

  @tag spec: "specled.tasks.review_html_artifact"
  test "writes a self-contained HTML file with no external network references", %{root: root} do
    setup_repo(root)
    record_base_evidence(root, [])

    Mix.Tasks.Spec.Review.run(["--root", root, "--base", "main"])

    output = Path.join([root, "_build", "spec_review.html"])
    assert File.exists?(output)

    content = File.read!(output)
    assert String.starts_with?(content, "<!DOCTYPE html>")
    assert content =~ "<style>"
    assert content =~ "<script>"
    # The two checks below are what actually enforce self-containment:
    # no external stylesheets are linked and no script src= refs are emitted.
    # Vendored libraries (Prism) inline their own source which may include
    # https:// URLs inside comments — that does not break self-containment.
    refute content =~ "<link rel=\"stylesheet\""
    refute content =~ "<script src="
    assert content =~ "This change introduces"
    refute content =~ "No base evidence is available"
  end

  @tag spec: "specled.spec_review.findings_delta_base_fallback"
  test "renders an indeterminate verdict and evidence healing instructions when base evidence is absent",
       %{root: root} do
    setup_repo(root)

    Mix.Tasks.Spec.Review.run(["--root", root, "--base", "main"])

    content = File.read!(Path.join([root, "_build", "spec_review.html"]))
    assert content =~ "Findings could not be attributed to this change."
    assert content =~ "No base evidence is available for the base tree"
    assert content =~ "mix spec.sync"
    assert content =~ "mix spec.check"
    refute content =~ "This change introduces no findings."
  end

  @tag spec: "specled.spec_review.same_artifact_local_and_ci"
  test "writes to a custom --output path when given", %{root: root} do
    setup_repo(root)

    custom = Path.join(root, "out/review.html")
    Mix.Tasks.Spec.Review.run(["--root", root, "--base", "main", "--output", custom])

    assert File.exists?(custom)
    refute File.exists?(Path.join([root, "_build", "spec_review.html"]))
  end

  @tag spec: "specled.spec_review.diff_against_base"
  test "rejects unknown flags", %{root: root} do
    setup_repo(root)

    assert_raise Mix.Error, ~r/Invalid arguments for spec\.review/, fn ->
      Mix.Tasks.Spec.Review.run(["--root", root, "--bogus"])
    end
  end

  defp setup_repo(root) do
    init_git_repo(root)

    write_subject_spec(
      root,
      "demo",
      meta: %{
        "id" => "demo.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => "Demo subject prose statement.",
        "surface" => ["lib/demo.ex"]
      }
    )

    write_files(root, %{"lib/demo.ex" => "defmodule Demo do\nend\n"})
    commit_all(root, "initial")

    write_files(root, %{"lib/demo.ex" => "defmodule Demo do\n  def run, do: :ok\nend\n"})
    :ok
  end

  defp record_base_evidence(root, findings) do
    tree_hash = root |> git!(["rev-parse", "main^{tree}"]) |> String.trim()

    entry =
      Entry.build(tree_hash, %{"findings" => findings},
        run_at: "2026-07-16T12:00:00.000000Z",
        run_id: String.duplicate("a", 32),
        specled_version: "test"
      )

    assert :ok = Store.record(root, entry)
  end
end
