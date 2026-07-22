defmodule Mix.Tasks.Spec.Evidence.MigrateTest do
  use SpecLedEx.Case, async: false

  @moduletag spec: [
               "specled.evidence_store.migration_one_shot",
               "specled.tasks.evidence_migrate"
             ]

  alias SpecLedEx.Evidence.{Store, TreeHash}
  alias SpecLedEx.Realization.HashStore

  test "migrates state.json to ignored derived state and seeds current-tree evidence once", %{
    root: root
  } do
    scaffold_legacy_workspace(root)

    baseline_path = Path.join(root, HashStore.baseline_rel())
    baseline_before = File.read!(baseline_path)

    Mix.Tasks.Spec.Evidence.Migrate.run(["--root", root])

    assert File.exists?(Path.join(root, ".spec/state.json"))
    assert git!(root, ["ls-files", "--", ".spec/state.json"]) == ""
    assert File.read!(Path.join(root, ".gitignore")) =~ ".spec/state.json\n"

    hook_path = Path.join(root, ".git/hooks/pre-push")
    assert File.read!(hook_path) == Mix.Tasks.Spec.Evidence.InstallHook.shim_bytes()

    {:ok, tree_hash} = TreeHash.current(root)
    assert {:ok, %{"tree_hash" => ^tree_hash}} = Store.read(root, tree_hash)
    assert File.read!(baseline_path) == baseline_before

    status_before = git!(root, ["status", "--short"])
    evidence_ref_before = String.trim(git!(root, ["rev-parse", "refs/heads/spec-evidence"]))

    Mix.Tasks.Spec.Evidence.Migrate.run(["--root", root])

    assert git!(root, ["status", "--short"]) == status_before

    assert String.trim(git!(root, ["rev-parse", "refs/heads/spec-evidence"])) ==
             evidence_ref_before

    assert File.read!(baseline_path) == baseline_before
  end

  test "hoists a legacy embedded realization baseline out of state.json", %{root: root} do
    legacy_realization = %{
      "api_boundary" => %{
        "Workspace.run/0" => %{
          "hash" => Base.encode16(:crypto.hash(:sha256, "legacy"), case: :lower),
          "hasher_version" => HashStore.hasher_version()
        }
      }
    }

    scaffold_legacy_workspace(root, baseline: false, embedded_realization: legacy_realization)

    baseline_path = Path.join(root, HashStore.baseline_rel())
    refute File.exists?(baseline_path)

    Mix.Tasks.Spec.Evidence.Migrate.run(["--root", root])

    assert message_contains?(drain_shell_messages(), "hoisted legacy realization baseline")

    assert File.exists?(baseline_path)
    hoisted = SpecLedEx.Json.read(baseline_path)

    assert hoisted["api_boundary"]["Workspace.run/0"]["hash"] ==
             legacy_realization["api_boundary"]["Workspace.run/0"]["hash"]

    hoisted_after_first_run = File.read!(baseline_path)

    Mix.Tasks.Spec.Evidence.Migrate.run(["--root", root])

    refute message_contains?(drain_shell_messages(), "hoisted legacy realization baseline")
    assert File.read!(baseline_path) == hoisted_after_first_run
  end

  defp scaffold_legacy_workspace(root, opts \\ []) do
    init_git_repo(root)

    write_files(root, %{"README.md" => "# Fixture\n"})

    write_subject_spec(
      root,
      "workspace",
      meta: %{"id" => "workspace.subject", "kind" => "module", "status" => "active"},
      requirements: [
        %{
          "id" => "workspace.requirement",
          "statement" => "The workspace fixture has a source-backed verification."
        }
      ],
      verification: [
        %{
          "kind" => "source_file",
          "target" => ".spec/specs/workspace.spec.md",
          "covers" => ["workspace.requirement"]
        }
      ]
    )

    if Keyword.get(opts, :baseline, true) do
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            "Workspace.run/0" => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "baseline"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })
    end

    root
    |> SpecLedEx.index()
    |> SpecLedEx.write_state(nil, root)

    case Keyword.get(opts, :embedded_realization) do
      nil ->
        :ok

      realization ->
        state_path = Path.join(root, ".spec/state.json")

        state_path
        |> SpecLedEx.Json.read()
        |> Map.put("realization", realization)
        |> then(&SpecLedEx.Json.write!(state_path, &1))
    end

    commit_all(root, "legacy state")
  end
end
