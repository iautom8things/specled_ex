defmodule SpecLedEx.SpecReviewWorkflowTest do
  @moduledoc """
  Command-tier guard for the GH Actions privilege split in the seeded
  `spec_review` workflow template.

  The `workflow_file` verification only asserts file presence + cover-id
  substring; this suite parses the YAML and pins the four clauses of
  `specled.spec_review.gh_pages_privilege_separation`.

  Operative clause (verbatim): the write-scoped job shall not check out or
  execute pull-request-provided code. Assertions quantify over those acts —
  not over a single `uses:` action name.
  """
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.spec_review.gh_pages_privilege_separation"]

  @workflow_path Path.expand("../../priv/spec_init/workflows/spec_review.yml.eex", __DIR__)
  # GitHub Actions expression form of the trusted base-branch pin. Deploy
  # must check out this ref (not PR head, not unpinned) so write-scoped
  # jobs never see pull-request-provided code.
  @base_ref_expr "${{ github.base_ref }}"
  @pr_head_ref_fragment "github.event.pull_request.head"
  # Legitimate deploy `uses:` set today (template deploy steps). A new
  # action is fail-closed so it cannot smuggle a checkout past a
  # name-filter that only knows actions/checkout.
  @deploy_allowed_uses MapSet.new([
                         "actions/checkout@v4",
                         "actions/download-artifact@v4"
                       ])

  setup_all do
    raw = File.read!(@workflow_path)
    # Template has zero EEx tags; parse as plain YAML (YAML 1.1 via yamerl).
    workflow = YamlElixir.read_from_string!(raw)
    {:ok, workflow: workflow}
  end

  describe "gh_pages_privilege_separation" do
    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "top-level permissions default to read-only", %{workflow: workflow} do
      # Exact map equality is the pin; a write-all binary or extra write
      # key both fail this single assertion.
      assert workflow["permissions"] == %{"contents" => "read"}
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
      # Exact pin — absent permissions would inherit top-level only, but
      # this clause asserts the job itself declares read-only contents.
      # Binary values (e.g. permissions: write-all) fail the map equality
      # with a readable assertion rather than Protocol.UndefinedError.
      assert render["permissions"] == %{"contents" => "read"}
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "deploy holds write scopes", %{workflow: workflow} do
      deploy = workflow["jobs"]["deploy"]

      assert deploy["permissions"] == %{
               "contents" => "write",
               "pull-requests" => "write"
             }
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "deploy does not check out pull-request-provided code", %{workflow: workflow} do
      deploy = workflow["jobs"]["deploy"]
      steps = List.wrap(deploy["steps"])

      # (c) allowlist: every uses: step must be in the known-safe set
      uses_steps =
        for step <- steps, is_binary(step["uses"]), do: step["uses"]

      unknown_uses = Enum.reject(uses_steps, &MapSet.member?(@deploy_allowed_uses, &1))

      assert unknown_uses == [],
             "deploy uses: must be allowlisted (checkout@v4, download-artifact@v4); got #{inspect(unknown_uses)}"

      # (a) every actions/checkout step pins with.ref to the trusted base ref
      checkout_steps =
        for step <- steps,
            is_binary(step["uses"]) and checkout_action?(step["uses"]),
            do: step

      assert checkout_steps != [],
             "deploy must include an actions/checkout step with a pinned base ref"

      for step <- checkout_steps do
        with_map = step["with"] || %{}
        ref = with_map["ref"]

        assert ref == @base_ref_expr,
               "deploy checkout must pin ref to #{inspect(@base_ref_expr)}; got #{inspect(ref)}"
      end

      # (b) every run: string must not acquire a PR ref (hand-rolled checkout)
      run_steps = for step <- steps, is_binary(step["run"]), do: step

      for step <- run_steps do
        run = step["run"]
        name = step["name"] || "(unnamed)"

        # `.+` (not `\S*`) so GH expressions with spaces still match, e.g.
        # pull/${{ github.event.pull_request.number }}/head — the critic's
        # demonstrated false-green shape. Also catches refs/pull/N/head.
        refute Regex.match?(~r{(?:refs/)?pull/.+/(head|merge)}, run),
               "deploy run must not fetch PR refs (pull/*/head|merge); step=#{inspect(name)}"

        refute String.contains?(run, @pr_head_ref_fragment),
               "deploy run must not reference #{@pr_head_ref_fragment}; step=#{inspect(name)}"
      end
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "deploy does not execute mix (PR-code surface); render does", %{workflow: workflow} do
      deploy = workflow["jobs"]["deploy"]
      render = workflow["jobs"]["render"]

      # Note: invokes_mix?/1 only inspects `run:` strings. Job-level
      # `uses:` reusable-workflow calls and step `uses:` actions that
      # shell out to mix are outside this detector's aperture.

      deploy_mix_steps =
        for step <- List.wrap(deploy["steps"]), invokes_mix?(step["run"]), do: step["name"]

      assert deploy_mix_steps == [],
             "deploy must not invoke mix (PR-code execution surface); steps: #{inspect(deploy_mix_steps)}"

      render_mix_steps =
        for step <- List.wrap(render["steps"]), invokes_mix?(step["run"]), do: step["name"]

      # Non-vacuity canary: if this is empty the detector is broken, not
      # the template — deploy's absence of mix would then be unproven.
      assert render_mix_steps != [],
             "sanity: render is expected to invoke mix; if empty, the detection pattern is wrong"
    end
  end

  # Action name without version pin (actions/checkout@v4 → actions/checkout).
  defp checkout_action?(uses) when is_binary(uses) do
    uses
    |> String.split("@", parts: 2)
    |> hd()
    |> Kernel.==("actions/checkout")
  end

  # Shell invocation of mix anywhere in a run block, not only at line start.
  # Catches: `mix …`, `MIX_ENV=prod mix …`, `cd x && mix …`, `./bin/mix …`,
  # `OUT=$(mix …)`, `bash -c 'mix …'`, `elixir -S mix …`.
  # Deliberately fail-closed on words ending in "mix" (`premix `) so a
  # renamed wrapper still trips. Does not match backticked prose such as
  # `` `mix spec.review` `` in deploy's PR comment body (template ~:184).
  #
  # Backtick spans are stripped per line so an odd number of backticks on
  # one line cannot pair with a distant line and swallow real commands
  # between them (fail-open hazard of a whole-string strip).
  defp invokes_mix?(run) when is_binary(run) do
    run
    |> String.split("\n")
    |> Enum.any?(fn line ->
      stripped = String.replace(line, ~r/`[^`]*`/, "")
      # (?<![\w.-]) avoids matching mid-identifier; [\w./-]*mix allows
      # path prefixes (./bin/mix) and is fail-closed on *mix suffixes.
      Regex.match?(~r{(?<![\w.-])[\w./-]*mix[ \t]}, stripped)
    end)
  end

  defp invokes_mix?(_), do: false
end
