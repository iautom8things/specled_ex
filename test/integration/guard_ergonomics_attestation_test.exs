defmodule SpecLedEx.Integration.GuardErgonomicsAttestationTest do
  # covers: specled.realized_by.orchestrator_publishes_attestations
  # covers: specled.realized_by.attestation_tagged_tests_expansion
  use ExUnit.Case, async: false

  alias SpecLedEx.Compiler.Context
  alias SpecLedEx.Realization.Orchestrator

  @moduletag :integration

  # ---------------------------------------------------------------------------
  # specled_-oyg — end-to-end proof that the attested-clean file-touch downgrade
  # fires against specled_ex's OWN realized_by bindings (not a synthetic
  # fixture). The file-touch guard downgrades a `(subject, file)` pair to
  # `:info` exactly when this attestation map carries an `{:attested_clean, _}`
  # entry for it (see `missing_subject_update_findings/4`), so asserting the map
  # is equivalent to asserting the downgrade for an internals-only edit.
  #
  # Two named coverage gaps are closed here:
  #   (1) implementation_tier maps `orchestrator_test.exs` into its coverage via
  #       the `hash_ref_composition` tagged test; the requirement now carries a
  #       requirement-level `api_boundary` binding on
  #       `Implementation.hashes_for_seeding/3` so the tagged_tests attestation
  #       expansion reaches that test file.
  #   (2) branch_guard's bare-module `implementation` bindings (`SpecLedEx.Coverage`,
  #       `SpecLedEx.Config.BranchGuard`) and its `Orchestrator.run/2`
  #       api_boundary binding attest their source files clean on a clean tree.
  # ---------------------------------------------------------------------------

  setup_all do
    root = File.cwd!()
    index = SpecLedEx.index(root, test_tags: true)
    ctx = Context.from_mix_project()

    attestations =
      Orchestrator.attestations(index, root: root, context: ctx, commit_hashes?: false)

    {:ok, attestations: attestations}
  end

  @tag spec: "specled.realized_by.orchestrator_publishes_attestations"
  test "branch_guard bindings attest orchestrator.ex and bare-module source files clean",
       %{attestations: attestations} do
    bg = Map.get(attestations, "specled.branch_guard", %{})

    # api_boundary MFA binding `SpecLedEx.Realization.Orchestrator.run/2`
    # resolves to orchestrator.ex; head-only hash is stable under an
    # internals-only edit, so the pair attests clean.
    assert match?(
             {:attested_clean, _},
             Map.get(bg, "lib/specled_ex/realization/orchestrator.ex")
           ),
           "expected orchestrator.ex attested for branch_guard; got #{inspect(bg)}"

    # bare-module `implementation` bindings surface under api_boundary via the
    # implication (head-union hash); they became real in specled_-rot.
    assert match?({:attested_clean, _}, Map.get(bg, "lib/specled_ex/coverage.ex")),
           "expected coverage.ex attested via SpecLedEx.Coverage bare module; got #{inspect(bg)}"

    assert match?({:attested_clean, _}, Map.get(bg, "lib/specled_ex/config/branch_guard.ex")),
           "expected config/branch_guard.ex attested via SpecLedEx.Config.BranchGuard bare module; got #{inspect(bg)}"
  end

  @tag spec: "specled.realized_by.attestation_tagged_tests_expansion"
  test "implementation_tier attests orchestrator_test.exs via hash_ref_composition tagged_tests expansion",
       %{attestations: attestations} do
    impl_tier = Map.get(attestations, "specled.implementation_tier", %{})

    test_path = "test/specled_ex/realization/orchestrator_test.exs"

    assert match?({:attested_clean, _}, Map.get(impl_tier, test_path)),
           "expected #{test_path} attested for implementation_tier via tagged_tests expansion; " <>
             "attested keys were #{inspect(Map.keys(impl_tier))}"
  end
end
