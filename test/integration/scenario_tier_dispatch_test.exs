defmodule SpecLedEx.Integration.ScenarioTierDispatchTest do
  # covers: specled.branch_guard.tier_dispatch_wires_orchestrator
  # covers: specled.branch_guard.tier_dispatch_surfaces_drift
  # covers: specled.branch_guard.tier_dispatch_surfaces_dangling
  use SpecLedEx.Case

  alias SpecLedEx.BranchCheck
  alias SpecLedEx.Index
  alias SpecLedEx.Realization.{ApiBoundary, Binding, HashStore}

  @moduletag :integration

  # ---------------------------------------------------------------------------
  # End-to-end smoke test for the q59.9 wiring: a real `.spec/specs/*.spec.md`
  # subject declares `realized_by.api_boundary` and BranchCheck.run/3 is the
  # entry. The realization findings produced by the Orchestrator must show up
  # in the BranchCheck report's findings list.
  # ---------------------------------------------------------------------------

  setup_all do
    # Compile a fixture module on disk so the api_boundary tier can resolve it
    # via the beam path the same way production calls do.
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_tier_dispatch_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    source_path = Path.join(tmp_dir, "tier_dispatch_fixture.ex")

    File.write!(source_path, """
    defmodule SpecLedEx.TierDispatchFixture.Mod do
      def foo(x), do: x + 1
    end
    """)

    {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)
    :code.add_patha(String.to_charlist(tmp_dir))

    mod = SpecLedEx.TierDispatchFixture.Mod
    :code.purge(mod)
    :code.delete(mod)
    {:module, ^mod} = :code.load_file(mod)

    on_exit(fn ->
      :code.del_path(String.to_charlist(tmp_dir))
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  describe "BranchCheck.run/3 dispatches realization tiers" do
    test "emits branch_guard_realization_drift for a drifted api_boundary binding",
         %{root: root} do
      mfa = "SpecLedEx.TierDispatchFixture.Mod.foo/1"

      init_git_repo(root)
      seed_repo(root)

      write_subject_spec(root, "dispatch",
        meta: %{
          "id" => "dispatch.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/dispatch.ex"],
          "realized_by" => %{"api_boundary" => [mfa]}
        },
        requirements: [
          %{"id" => "dispatch.req", "statement" => "x", "priority" => "must"}
        ]
      )

      commit_all(root, "seed subject + fixture")

      # Seed the store with a WRONG hash so the current hash disagrees with
      # committed -> drift finding.
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      index = Index.build(root)

      report =
        BranchCheck.run(index, root,
          base: "HEAD",
          commit_realization_hashes?: false
        )

      findings = report["findings"] || []

      drift =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["tier"] == "api_boundary"
        end)

      assert drift != nil,
             "expected api_boundary drift finding, got:\n" <> inspect(findings, pretty: true)

      assert drift["mfa"] == mfa
      assert drift["subject_id"] == "dispatch.subject"

      # Severity must resolve to :warning per @per_code_defaults for this code.
      assert drift["severity"] == "warning"
    end

    test "emits branch_guard_dangling_binding for an unresolvable api_boundary MFA",
         %{root: root} do
      init_git_repo(root)
      seed_repo(root)

      write_subject_spec(root, "dangle",
        meta: %{
          "id" => "dangle.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/dangle.ex"],
          "realized_by" => %{"api_boundary" => ["SpecLedEx.Nope.ghost/3"]}
        },
        requirements: [
          %{"id" => "dangle.req", "statement" => "x", "priority" => "must"}
        ]
      )

      commit_all(root, "seed dangling")

      index = Index.build(root)

      report =
        BranchCheck.run(index, root,
          base: "HEAD",
          commit_realization_hashes?: false
        )

      findings = report["findings"] || []

      dangling =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_dangling_binding" and f["tier"] == "api_boundary"
        end)

      assert dangling != nil,
             "expected dangling-binding finding, got:\n" <> inspect(findings, pretty: true)

      assert dangling["subject_id"] == "dangle.subject"
      assert dangling["severity"] == "error"
      assert String.contains?(dangling["message"], "SpecLedEx.Nope.ghost/3")
    end

    test "no drift finding when committed hash matches current (baseline seeded)",
         %{root: root} do
      mfa = "SpecLedEx.TierDispatchFixture.Mod.foo/1"

      init_git_repo(root)
      seed_repo(root)

      write_subject_spec(root, "clean",
        meta: %{
          "id" => "clean.subject",
          "kind" => "module",
          "status" => "active",
          "surface" => ["lib/clean.ex"],
          "realized_by" => %{"api_boundary" => [mfa]}
        },
        requirements: [
          %{"id" => "clean.req", "statement" => "x", "priority" => "must"}
        ]
      )

      commit_all(root, "seed clean")

      # Seed the store with the CURRENT hash so no drift is expected.
      {:ok, ast} = Binding.resolve(mfa)
      current = ApiBoundary.hash(ast)

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(current, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      index = Index.build(root)

      report =
        BranchCheck.run(index, root,
          base: "HEAD",
          commit_realization_hashes?: false
        )

      findings = report["findings"] || []

      refute Enum.any?(findings, fn f ->
               f["code"] in ["branch_guard_realization_drift", "branch_guard_dangling_binding"]
             end),
             "expected no tier findings for clean baseline, got:\n" <>
               inspect(findings, pretty: true)
    end
  end

  defp seed_repo(root) do
    write_files(root, %{"README.md" => "init\n"})
    commit_all(root, "initial")
  end
end
