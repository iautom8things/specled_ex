defmodule Mix.Tasks.SpecReviewTaskTest do
  use SpecLedEx.Case

  setup do
    Mix.Task.reenable("spec.review")
    :ok
  end

  @tag spec: "specled.spec_review.html_artifact"
  test "writes a self-contained HTML file with no external network references", %{root: root} do
    setup_repo(root)

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
end
