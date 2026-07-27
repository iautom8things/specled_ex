defmodule SpecLedEx.SpecReviewWorkflowTest do
  @moduledoc """
  Command-tier guard for the GH Actions privilege split in the seeded
  `spec_review` workflow template.

  The `workflow_file` verification only asserts file presence + cover-id
  substring; this suite parses the YAML and pins the four clauses of
  `specled.spec_review.gh_pages_privilege_separation`.
  """
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.spec_review.gh_pages_privilege_separation"]

  @workflow_path "priv/spec_init/workflows/spec_review.yml.eex"
  # GitHub Actions expression form of the trusted base-branch pin. Deploy
  # must check out this ref (not PR head, not unpinned) so write-scoped
  # jobs never see pull-request-provided code.
  @base_ref_expr "${{ github.base_ref }}"
  @pr_head_ref_fragment "github.event.pull_request.head"

  setup_all do
    raw = File.read!(@workflow_path)
    # Template has zero EEx tags; parse as plain YAML (YAML 1.1 via yamerl).
    workflow = YamlElixir.read_from_string!(raw)
    {:ok, workflow: workflow}
  end

  describe "gh_pages_privilege_separation" do
    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "top-level permissions default to read-only", %{workflow: workflow} do
      permissions = workflow["permissions"]

      assert permissions == %{"contents" => "read"}

      write_scopes =
        permissions
        |> Map.to_list()
        |> Enum.filter(fn {_k, v} -> v == "write" end)

      assert write_scopes == [],
             "top-level permissions must not grant write; got #{inspect(write_scopes)}"
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "two-job split: render and deploy, deploy needs render", %{workflow: workflow} do
      jobs = workflow["jobs"]
      assert is_map(jobs)

      assert Map.keys(jobs) |> Enum.sort() == ["deploy", "render"]

      deploy = jobs["deploy"]
      needs = List.wrap(deploy["needs"])

      assert "render" in needs,
             "deploy must depend on render (needs includes render); got #{inspect(deploy["needs"])}"
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "render holds no write scope", %{workflow: workflow} do
      render = workflow["jobs"]["render"]
      permissions = render["permissions"] || %{}

      for {scope, level} <- permissions do
        assert level in ~w(read none),
               "render must not hold write scope; got #{inspect(scope)} => #{inspect(level)}"
      end

      refute permissions["pull-requests"] == "write"
      refute permissions["contents"] == "write"
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "deploy holds write scopes, pins base-ref checkout, and runs no mix", %{
      workflow: workflow
    } do
      deploy = workflow["jobs"]["deploy"]
      render = workflow["jobs"]["render"]

      assert deploy["permissions"] == %{
               "contents" => "write",
               "pull-requests" => "write"
             }

      checkout_steps =
        for step <- List.wrap(deploy["steps"]),
            is_binary(step["uses"]) and String.starts_with?(step["uses"], "actions/checkout"),
            do: step

      assert checkout_steps != [],
             "deploy must include an actions/checkout step with a pinned base ref"

      for step <- checkout_steps do
        with_map = step["with"] || %{}
        ref = with_map["ref"]

        assert ref == @base_ref_expr,
               "deploy checkout must pin ref to #{inspect(@base_ref_expr)}; got #{inspect(ref)}"

        refute is_nil(ref), "deploy checkout must not be unpinned (missing with.ref)"

        refute is_binary(ref) and String.contains?(ref, @pr_head_ref_fragment),
               "deploy checkout must not use PR head ref; got #{inspect(ref)}"
      end

      deploy_mix_steps =
        for step <- List.wrap(deploy["steps"]), invokes_mix?(step["run"]), do: step["name"]

      assert deploy_mix_steps == [],
             "deploy must not invoke mix (PR-code execution surface); steps: #{inspect(deploy_mix_steps)}"

      render_mix_steps =
        for step <- List.wrap(render["steps"]), invokes_mix?(step["run"]), do: step["name"]

      assert render_mix_steps != [],
             "sanity: render is expected to invoke mix; if empty, the detection pattern is wrong"
    end
  end

  # Shell-command invocation of mix: a line that is (optionally indented) `mix …`.
  # Deliberately does not match string mentions such as `` `mix spec.review` ``
  # embedded in deploy's PR comment body.
  defp invokes_mix?(run) when is_binary(run), do: Regex.match?(~r/(^|\n)[ \t]*mix[ \t]/, run)
  defp invokes_mix?(_), do: false
end
