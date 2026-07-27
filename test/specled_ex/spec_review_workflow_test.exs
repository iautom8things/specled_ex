defmodule SpecLedEx.SpecReviewWorkflowTest do
  @moduledoc """
  Command-tier guard for the GH Actions privilege split in the seeded
  `spec_review` workflow template.

  The `workflow_file` verification only asserts file presence + cover-id
  substring; this suite parses the YAML and pins the four clauses of
  `specled.spec_review.gh_pages_privilege_separation`.

  Operative clause (verbatim): the write-scoped job shall not check out or
  execute pull-request-provided code. Assertions quantify over those acts —
  not over a single spelling of a PR-head expression.

  Shape (deny-by-default):

  * **Level A** — `uses:` exact action@version allowlist, plus a per-action
    `with:`-KEY allowlist (`actions/checkout` ⇒ `{ref}` only;
    `actions/download-artifact` ⇒ `{name, path}` only).
  * **Level B** — deploy `run:` ref acquisition: no checkout-class verbs at
    all (B1); every `git fetch` / `git worktree add` line has non-flag
    operands drawn from a trusted set (B2). New aliases fail by omission
    from the allowlist, not by presence on a forbidden list.
  * **Level C** — deploy must not invoke `mix`, must not execute paths under
    the artifact download directory (`rendered/`), and must not run
    `elixir -e` / `elixir -S`.

  Declared aperture (outside this detector by construction — closing them
  needs a shell parser or workflow interpreter):

  * shell variable indirection (e.g. `RUNNER=mix; $RUNNER …`)
  * arbitrary interpreters invoked on non-`rendered/` paths
  * job-level reusable-workflow `uses:` that shell out to mix/checkout
  """
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.spec_review.gh_pages_privilege_separation"]

  @workflow_path Path.expand("../../priv/spec_init/workflows/spec_review.yml.eex", __DIR__)
  # GitHub Actions expression form of the trusted base-branch pin.
  @base_ref_expr "${{ github.base_ref }}"
  # Belt-and-braces only — soundness comes from Level A/B, not this fragment.
  @pr_head_ref_fragment "github.event.pull_request.head"
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
    test "deploy does not check out pull-request-provided code", %{workflow: workflow} do
      deploy = workflow["jobs"]["deploy"]
      steps = List.wrap(deploy["steps"])

      # ── Level A: uses: allowlist + with:-KEY allowlist ──────────────────
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

      # ── Level B: run: deny-by-default ref acquisition ───────────────────
      run_steps = for step <- steps, is_binary(step["run"]), do: step

      acquisition_lines =
        for step <- run_steps,
            line <- String.split(step["run"], "\n"),
            acquisition_line?(line),
            do: {step["name"] || "(unnamed)", line}

      # Non-vacuity canary: template has three acquisition lines today
      # (fetch + worktree add ×2). Empty means B1/B2 are silently vacuous.
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

      for step <- run_steps do
        run = step["run"]
        name = step["name"] || "(unnamed)"

        # B1 — no checkout-class verb at all (zero legitimate uses in deploy).
        # Matchers are verb-specific so `git add` ≠ `git worktree add` and
        # `gh pr comment` ≠ `gh pr checkout`.
        refute checkout_class_verb?(run),
               "deploy run must not use checkout-class verbs " <>
                 "(git checkout|switch|clone|pull|reset --hard, gh pr checkout, gh repo clone); " <>
                 "step=#{inspect(name)}"

        # Belt-and-braces only — primary soundness is B1+B2 above.
        refute Regex.match?(~r{(?:refs/)?pull/.+/(head|merge)}, run),
               "deploy run must not fetch PR refs (pull/*/head|merge); step=#{inspect(name)}"

        refute String.contains?(run, @pr_head_ref_fragment),
               "deploy run must not reference #{@pr_head_ref_fragment}; step=#{inspect(name)}"
      end
    end

    @tag spec: "specled.spec_review.gh_pages_privilege_separation"
    test "deploy does not execute PR-provided code; render does invoke mix", %{workflow: workflow} do
      deploy = workflow["jobs"]["deploy"]
      render = workflow["jobs"]["render"]

      deploy_steps = List.wrap(deploy["steps"])
      run_steps = for step <- deploy_steps, is_binary(step["run"]), do: step

      # Level C — mix token (existing). Note: only inspects `run:` strings.
      deploy_mix_steps =
        for step <- deploy_steps, invokes_mix?(step["run"]), do: step["name"]

      assert deploy_mix_steps == [],
             "deploy must not invoke mix (PR-code execution surface); steps: #{inspect(deploy_mix_steps)}"

      # C1 — no execution of paths under the artifact download dir (rendered/).
      for step <- run_steps do
        name = step["name"] || "(unnamed)"

        refute executes_rendered_path?(step["run"]),
               "deploy run must not execute paths under rendered/ " <>
                 "(command position, interpreter arg, or .sh|.exs|.py|.js suffix); " <>
                 "step=#{inspect(name)}"
      end

      # C2 — no elixir -e / elixir -S in deploy (zero legitimate uses).
      for step <- run_steps do
        name = step["name"] || "(unnamed)"

        refute elixir_eval?(step["run"]),
               "deploy run must not invoke elixir -e / elixir -S; step=#{inspect(name)}"
      end

      render_mix_steps =
        for step <- List.wrap(render["steps"]), invokes_mix?(step["run"]), do: step["name"]

      # Non-vacuity canary: if this is empty the detector is broken, not
      # the template — deploy's absence of mix would then be unproven.
      assert render_mix_steps != [],
             "sanity: render is expected to invoke mix; if empty, the detection pattern is wrong"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp action_name(uses) when is_binary(uses) do
    uses |> String.split("@", parts: 2) |> hd()
  end

  # B1: checkout-class verbs. Word-boundary style so `git add` and
  # `gh pr comment` do not false-positive.
  defp checkout_class_verb?(run) when is_binary(run) do
    patterns = [
      ~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+checkout(?:[ \t]|$)},
      ~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+switch(?:[ \t]|$)},
      ~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+clone(?:[ \t]|$)},
      ~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+pull(?:[ \t]|$)},
      ~r{(?:^|[^a-zA-Z0-9_./-])git[ \t]+reset[ \t]+--hard(?:[ \t]|$)},
      ~r{(?:^|[^a-zA-Z0-9_./-])gh[ \t]+pr[ \t]+checkout(?:[ \t]|$)},
      ~r{(?:^|[^a-zA-Z0-9_./-])gh[ \t]+repo[ \t]+clone(?:[ \t]|$)}
    ]

    Enum.any?(patterns, &Regex.match?(&1, run))
  end

  # B2 verb matcher: git fetch OR git worktree add (not bare `git add`).
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

  # C1: execute a path under rendered/ — command position, interpreter arg,
  # or executable suffix. `cp rendered/spec_review.html …` stays green.
  defp executes_rendered_path?(run) when is_binary(run) do
    run
    |> String.split("\n")
    |> Enum.any?(fn line ->
      s = String.replace(line, ~r/`[^`]*`/, "")

      has_exec_suffix? =
        Regex.match?(
          ~r{(?:^|[\s"'=])(?:\./)?rendered/[^\s"']*\.(?:sh|exs|py|js)\b},
          s
        )

      has_interpreter? =
        Regex.match?(
          ~r{(?:^|[\s;&|`(])(?:bash|sh|source|elixir|mix|python|node)[ \t]+[^\n#]*rendered/},
          s
        ) or
          Regex.match?(~r{(?:^|[\s;&|`(])\.[ \t]+[^\n#]*rendered/}, s)

      # Command position: start of a simple command (line start or after
      # ;|&, NOT after ordinary whitespace — so `cp rendered/…` stays green).
      has_cmd_pos? =
        Regex.match?(
          ~r{(?:^|[;&|])[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*=\S*[ \t]+)*(?:\./)?rendered/},
          s
        )

      has_exec_suffix? or has_interpreter? or has_cmd_pos?
    end)
  end

  defp executes_rendered_path?(_), do: false

  # C2: elixir -e / elixir -S
  defp elixir_eval?(run) when is_binary(run) do
    Regex.match?(~r{(?:^|[^a-zA-Z0-9_./-])elixir[ \t]+-(?:e|S)(?:[ \t]|$)}, run)
  end

  defp elixir_eval?(_), do: false

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
