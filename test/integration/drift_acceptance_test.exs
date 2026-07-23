defmodule SpecLedEx.Integration.DriftAcceptanceTest do
  # covers: specled.realized_by.drift_acceptance
  use SpecLedEx.Case

  alias SpecLedEx.BranchCheck
  alias SpecLedEx.Index
  alias SpecLedEx.Realization.{ApiBoundary, Binding, HashStore}

  @moduletag :integration

  # ---------------------------------------------------------------------------
  # specled_-uv3 — `mix spec.check --accept-drift` is the durable acceptance
  # path for intentional realization drift. We bind a subject to a real, stable
  # host MFA and seed a deliberately WRONG committed hash to manufacture drift,
  # then assert that an accepting run (a) passes with the drift downgraded to
  # `:info`, (b) rewrites the committed baseline to the current hash, and (c)
  # leaves a subsequent non-accepting run clean — the drift does not resurface.
  #
  # A dangling binding is NOT accepted: accept mode still fails the run and
  # commits no hash for a binding that does not resolve.
  # ---------------------------------------------------------------------------

  @real_mfa "SpecLedEx.Coverage.default_artifact_path/0"

  @tag spec: "specled.realized_by.drift_acceptance"
  test "--accept-drift refreshes the baseline, downgrades drift to :info, and self-heals",
       %{root: root} do
    init_git_repo(root)
    seed_repo(root)

    write_subject_spec(root, "accept",
      meta: %{
        "id" => "accept.subject",
        "kind" => "module",
        "status" => "active",
        "surface" => ["lib/accept.ex"],
        "realized_by" => %{"api_boundary" => [@real_mfa]}
      },
      requirements: [
        %{"id" => "accept.req", "statement" => "x", "priority" => "must"}
      ]
    )

    commit_all(root, "seed accept subject")

    wrong_hash = Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower)

    :ok =
      HashStore.write(root, %{
        "api_boundary" => %{
          @real_mfa => %{"hash" => wrong_hash, "hasher_version" => HashStore.hasher_version()}
        }
      })

    index = Index.build(root)

    # Accepting run: refresh the baseline even though drift is present.
    report =
      BranchCheck.run(index, root,
        base: "HEAD",
        commit_realization_hashes?: true,
        accept_drift?: true
      )

    findings = report["findings"] || []

    drift =
      Enum.find(findings, fn f ->
        f["code"] == "branch_guard_realization_drift" and f["mfa"] == @real_mfa
      end)

    assert drift != nil,
           "expected the accepted drift to remain visible, got:\n" <>
             inspect(findings, pretty: true)

    assert drift["severity"] == "info",
           "accepted drift must downgrade to :info, got #{inspect(drift["severity"])}"

    assert report["status"] == "pass",
           "accepting run must pass, got:\n" <> inspect(report, pretty: true)

    # The committed baseline now holds the CURRENT hash, not the wrong one.
    {:ok, ast} = Binding.resolve(@real_mfa)
    expected = Base.encode16(ApiBoundary.hash(ast), case: :lower)
    store = HashStore.read(root)
    assert get_in(store, ["api_boundary", @real_mfa, "hash"]) == expected

    # A subsequent non-accepting run sees committed == current: no drift.
    report2 =
      BranchCheck.run(index, root, base: "HEAD", commit_realization_hashes?: false)

    refute Enum.any?(report2["findings"] || [], fn f ->
             f["code"] == "branch_guard_realization_drift" and f["mfa"] == @real_mfa
           end),
           "drift must not resurface after acceptance, got:\n" <>
             inspect(report2["findings"], pretty: true)
  end

  @tag spec: "specled.realized_by.drift_acceptance"
  test "--accept-drift does not absorb a dangling binding", %{root: root} do
    ghost = "SpecLedEx.Nope.ghost/3"

    init_git_repo(root)
    seed_repo(root)

    write_subject_spec(root, "dangle_accept",
      meta: %{
        "id" => "dangle_accept.subject",
        "kind" => "module",
        "status" => "active",
        "surface" => ["lib/dangle_accept.ex"],
        "realized_by" => %{"api_boundary" => [ghost]}
      },
      requirements: [
        %{"id" => "dangle_accept.req", "statement" => "x", "priority" => "must"}
      ]
    )

    commit_all(root, "seed dangling accept subject")

    index = Index.build(root)

    report =
      BranchCheck.run(index, root,
        base: "HEAD",
        commit_realization_hashes?: true,
        accept_drift?: true
      )

    findings = report["findings"] || []

    dangling =
      Enum.find(findings, fn f ->
        f["code"] == "branch_guard_dangling_binding" and f["mfa"] == ghost
      end)

    assert dangling != nil,
           "dangling binding must still surface under accept mode, got:\n" <>
             inspect(findings, pretty: true)

    assert dangling["severity"] == "error",
           "dangling binding is not accepted; it stays :error"

    assert report["status"] == "fail", "a dangling binding must still fail the run"

    store = HashStore.read(root)

    assert get_in(store, ["api_boundary", ghost]) == nil,
           "no hash may be committed for an unresolved binding"
  end

  defp seed_repo(root) do
    write_files(root, %{"README.md" => "init\n"})
    commit_all(root, "initial")
  end
end
