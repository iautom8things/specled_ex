defmodule Mix.Tasks.SpecSyncTaskTest do
  use SpecLedEx.Case, async: false

  alias SpecLedEx.Evidence.{Entry, Store}

  @moduletag spec: [
               "specled.evidence_store.sync_tree_union",
               "specled.evidence_store.sync_failure_contracts",
               "specled.evidence_store.drift_surfaced",
               "specled.tasks.sync_evidence"
             ]

  setup do
    Mix.Task.reenable("spec.sync")
    :ok
  end

  @tag spec: ["specled.evidence_store.sync_tree_union", "specled.evidence_store.drift_surfaced"]
  test "task drives the production Sync.run/2 path through a real bare-origin push", %{root: root} do
    repo = remote_repo!(root)

    entry =
      Entry.build(String.duplicate("a", 40), %{},
        run_at: "10",
        run_id: "a",
        specled_version: "test"
      )

    assert :ok = Store.record(repo, entry)

    assert :ok = Mix.Tasks.Spec.Sync.run(["--root", repo])
    messages = drain_shell_messages()

    assert message_contains?(messages, "spec-evidence drift as of last fetch: ahead=1 behind=0")
    assert git!(repo, ["ls-remote", "origin", "refs/heads/spec-evidence"]) != ""
  end

  @tag spec: "specled.evidence_store.sync_failure_contracts"
  test "default raises while best-effort emits exactly one warning and returns ok", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "fixture\n"})
    commit_all(root, "initial")

    assert_raise Mix.Error, ~r/evidence\/sync_failed/, fn ->
      Mix.Tasks.Spec.Sync.run(["--root", root])
    end

    Mix.Task.reenable("spec.sync")
    Mix.Shell.Process.flush()
    assert :ok = Mix.Tasks.Spec.Sync.run(["--root", root, "--best-effort"])

    warnings = drain_shell_messages() |> Enum.filter(&String.contains?(&1, "warning:"))
    assert length(warnings) == 1
    assert hd(warnings) =~ "evidence/sync_failed"
  end

  defp remote_repo!(root) do
    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    git!(root, ["init", "--bare", origin])
    File.mkdir_p!(repo)
    init_git_repo(repo)
    write_files(repo, %{"README.md" => "fixture\n"})
    commit_all(repo, "initial")
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-u", "origin", "main"])
    repo
  end
end
