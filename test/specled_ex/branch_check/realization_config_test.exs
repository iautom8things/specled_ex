defmodule SpecLedEx.BranchCheck.RealizationConfigTest do
  use SpecLedEx.Case

  alias SpecLedEx.{BranchCheck, Index, StateJsonFixture}
  alias SpecLedEx.Realization.HashStore

  @moduletag :capture_log

  @bare_module "SpecLedEx.Coverage"

  @tag spec: [
         "specled.branch_guard.realization_tiers_from_config",
         "specled.implementation_tier.config_opt_in"
       ]
  test "enabled_tiers including implementation runs the implementation tier", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".spec/config.yml" => """
      realization:
        enabled_tiers:
          - api_boundary
          - implementation
      """
    })

    write_realization_subject(root)
    commit_all(root, "initial realization config")

    report = BranchCheck.run(Index.build(root), root, base: "HEAD")

    assert report["status"] == "pass"

    store = HashStore.read(root)
    assert HashStore.fetch(store, "api_boundary", @bare_module)
    assert HashStore.fetch(store, "implementation", @bare_module)
  end

  @tag spec: "specled.branch_guard.realization_tiers_from_config"
  test "absent realization config keeps the orchestrator default tier set", %{root: root} do
    init_git_repo(root)
    write_realization_subject(root)
    commit_all(root, "initial without realization config")

    report = BranchCheck.run(Index.build(root), root, base: "HEAD")

    assert report["status"] == "pass"

    store = HashStore.read(root)
    assert HashStore.fetch(store, "api_boundary", @bare_module)
    refute Map.has_key?(store, "implementation")
    refute Enum.any?(report["findings"], &(&1["tier"] == "implementation"))
  end

  @tag spec: "specled.branch_guard.realization_tiers_from_config"
  test "explicit empty enabled_tiers runs no tiers and preserves committed hashes", %{root: root} do
    init_git_repo(root)

    api_hash = :crypto.hash(:sha256, "api-boundary-before")
    implementation_hash = :crypto.hash(:sha256, "implementation-before")

    write_files(root, %{
      ".spec/config.yml" => """
      realization:
        enabled_tiers: []
      """
    })

    write_realization_subject(root)

    :ok =
      StateJsonFixture.seed(root, %{
        "api_boundary" => %{@bare_module => api_hash},
        "implementation" => %{@bare_module => implementation_hash}
      })

    commit_all(root, "initial empty realization config")

    report = BranchCheck.run(Index.build(root), root, base: "HEAD")

    assert report["status"] == "pass"

    store = HashStore.read(root)
    assert HashStore.fetch(store, "api_boundary", @bare_module) == api_hash
    assert HashStore.fetch(store, "implementation", @bare_module) == implementation_hash
  end

  @tag spec: "specled.branch_guard.realization_unknown_tier_finding"
  test "rejected realization tier names emit a branch guard finding that can be disabled",
       %{root: root} do
    init_git_repo(root)
    write_empty_subject(root)

    write_files(root, %{
      ".spec/config.yml" => """
      realization:
        enabled_tiers:
          - made_up
          - api_boundary
      """
    })

    commit_all(root, "initial unknown tier")

    report = BranchCheck.run(Index.build(root), root, base: "HEAD")

    assert [finding] = realization_unknown_tier_findings(report)
    assert finding["severity"] == "warning"
    assert finding["file"] == ".spec/config.yml"
    assert finding["message"] =~ "realization.enabled_tiers contains unknown tier made_up"

    assert finding["message"] =~
             "valid tiers: api_boundary, implementation, expanded_behavior, typespecs, use"

    write_files(root, %{
      ".spec/config.yml" => """
      branch_guard:
        severities:
          branch_guard_realization_unknown_tier: off
      realization:
        enabled_tiers:
          - made_up
          - api_boundary
      """
    })

    commit_all(root, "disable unknown tier finding")

    report = BranchCheck.run(Index.build(root), root, base: "HEAD")

    assert realization_unknown_tier_findings(report) == []
  end

  defp write_realization_subject(root) do
    write_subject_spec(root, "realization_config",
      meta: %{
        "id" => "realization.config.subject",
        "kind" => "module",
        "status" => "active",
        "surface" => [],
        "realized_by" => %{"implementation" => [@bare_module]}
      }
    )
  end

  defp write_empty_subject(root) do
    write_subject_spec(root, "realization_config_empty",
      meta: %{
        "id" => "realization.config.empty",
        "kind" => "module",
        "status" => "active",
        "surface" => []
      }
    )
  end

  defp realization_unknown_tier_findings(report) do
    Enum.filter(
      report["findings"],
      &(&1["code"] == "branch_guard_realization_unknown_tier")
    )
  end
end
