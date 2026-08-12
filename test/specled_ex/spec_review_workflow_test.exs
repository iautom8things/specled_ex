defmodule SpecLedEx.SpecReviewWorkflowTest do
  @moduledoc """
  Command-tier guard for the GH Actions privilege split in the seeded
  `spec_review` workflow template.

  The `workflow_file` verification only asserts file presence + cover-id
  substring. This suite parses the YAML and checks the structural boundary:
  read-only defaults, separate render/deploy jobs, write-scope placement,
  allowlisted deploy actions with a base-ref pin, and trusted operands on the
  workflow's known `git fetch` / `git worktree add` acquisition lines.

  It deliberately makes no claim about the semantics of arbitrary `run:`
  text. That is an open set requiring a shell/workflow interpreter rather than
  another command-spelling matcher.
  """
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.spec_review.gh_pages_privilege_separation"]

  @workflow_path Path.expand("../../priv/spec_init/workflows/spec_review.yml.eex", __DIR__)
  # GitHub Actions expression form of the trusted base-branch pin.
  @base_ref_expr "${{ github.base_ref }}"
  # Legitimate deploy `uses:` set today (template deploy steps). A new
  # action is fail-closed so it cannot smuggle a checkout past a
  # name-filter that only knows actions/checkout.
  @deploy_allowed_uses MapSet.new([
                         "actions/checkout@v4",
                         "actions/download-artifact@v4"
                       ])
  # Per-action with:-KEY allowlist (keys only — not values). Any other key
  # fails closed (repository:, token:, ssh-key:, submodules:, …).
  @with_key_allowlists %{
    "actions/checkout" => MapSet.new(["ref"]),
    "actions/download-artifact" => MapSet.new(["name", "path"])
  }
  # Trusted non-flag operands for deploy's git fetch / git worktree add lines.
  # Widening this set is a deliberate security decision — do not "fix" it.
  @acquisition_operand_allowlist MapSet.new([
                                   "origin",
                                   "gh-pages",
                                   "gh-pages:gh-pages",
                                   "\"$DEPLOY_DIR\""
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
    test "deploy pins structural checkout and acquisition inputs", %{workflow: workflow} do
      deploy = workflow["jobs"]["deploy"]
      steps = List.wrap(deploy["steps"])

      # `uses:` allowlist + `with:`-key allowlist.
      uses_steps =
        for step <- steps, is_binary(step["uses"]), do: step

      unknown_uses =
        for step <- uses_steps,
            not MapSet.member?(@deploy_allowed_uses, step["uses"]),
            do: step["uses"]

      assert unknown_uses == [],
             "deploy uses: must be allowlisted (checkout@v4, download-artifact@v4); got #{inspect(unknown_uses)}"

      checkout_steps =
        for step <- uses_steps, action_name(step["uses"]) == "actions/checkout", do: step

      assert checkout_steps != [],
             "deploy must include an actions/checkout step with a pinned base ref"

      for step <- uses_steps do
        name = action_name(step["uses"])
        # Unknown actions already fail the uses allowlist above; skip key
        # checks for them so a single mutant does not raise KeyError.
        case Map.fetch(@with_key_allowlists, name) do
          {:ok, allowed} ->
            with_map = step["with"] || %{}
            keys = MapSet.new(Map.keys(with_map))
            extra = MapSet.difference(keys, allowed)

            assert MapSet.size(extra) == 0,
                   "deploy #{name} with: keys must be subset of #{inspect(MapSet.to_list(allowed))}; " <>
                     "extra=#{inspect(MapSet.to_list(extra))} (step=#{inspect(step["name"])})"

          :error ->
            :ok
        end
      end

      for step <- checkout_steps do
        with_map = step["with"] || %{}
        ref = with_map["ref"]

        assert ref == @base_ref_expr,
               "deploy checkout must pin ref to #{inspect(@base_ref_expr)}; got #{inspect(ref)}"
      end

      # Trusted operands on the known ref-acquisition commands.
      run_steps = for step <- steps, is_binary(step["run"]), do: step

      acquisition_lines =
        for step <- run_steps,
            line <- String.split(step["run"], "\n"),
            acquisition_line?(line),
            do: {step["name"] || "(unnamed)", line}

      # Non-vacuity canary: template has three acquisition lines today
      # (fetch + worktree add ×2).
      assert acquisition_lines != [],
             "sanity: deploy must contain git fetch / git worktree add lines; " <>
               "if empty, the acquisition matcher is broken or the template lost them"

      for {name, line} <- acquisition_lines do
        bad =
          line
          |> acquisition_operands()
          |> Enum.reject(&MapSet.member?(@acquisition_operand_allowlist, &1))

        assert bad == [],
               "deploy acquisition operands must be allowlisted " <>
                 "(origin|gh-pages|gh-pages:gh-pages|\"$DEPLOY_DIR\"); " <>
                 "offending=#{inspect(bad)} line=#{inspect(String.trim(line))} step=#{inspect(name)}. " <>
                 "Widen @acquisition_operand_allowlist only deliberately."
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp action_name(uses) when is_binary(uses) do
    uses |> String.split("@", parts: 2) |> hd()
  end

  # Select the acquisition commands whose operands the guard constrains.
  defp acquisition_line?(line) when is_binary(line) do
    Regex.match?(~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+fetch(?:[ \t]|$)}, line) or
      Regex.match?(~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+worktree[ \t]+add(?:[ \t]|$)}, line)
  end

  defp acquisition_operands(line) when is_binary(line) do
    stripped =
      line
      |> String.replace(~r/#.*$/, "")
      |> String.trim()

    tokens = shell_tokens(stripped)

    rest =
      case tokens do
        ["git", "fetch" | r] -> r
        ["git", "worktree", "add" | r] -> r
        _ -> tokens
      end

    # Drop flags (`--orphan`, `-b`, …). Flag *values* stay and must be
    # allowlisted (e.g. `-b gh-pages` leaves `gh-pages`).
    Enum.reject(rest, &String.starts_with?(&1, "-"))
  end

  defp shell_tokens(line) do
    Regex.scan(~r/"[^"]*"|'[^']*'|\S+/, line)
    |> Enum.map(&hd/1)
  end
end
