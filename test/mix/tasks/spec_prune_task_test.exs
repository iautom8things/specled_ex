defmodule Mix.Tasks.SpecPruneTaskTest do
  use SpecLedEx.Case, async: false

  import SpecLedEx.EvidenceHelpers

  alias SpecLedEx.Evidence.{Entry, Store, Sync}

  @moduletag spec: [
               "specled.evidence_store.prune_explicit_only",
               "specled.evidence_store.prune_reachability_floor",
               "specled.evidence_store.sync_entry_tolerance",
               "specled.tasks.prune_evidence"
             ]

  setup do
    Mix.Task.reenable("spec.prune")
    :ok
  end

  @tag spec: "specled.evidence_store.prune_explicit_only"
  test "explicit prune keeps local-head and remote-tracking trees and drops only unreachable", %{
    root: root
  } do
    %{repo: repo, peer: peer} = fixture!(root)
    local_tree = repo |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    write_files(peer, %{"REMOTE.md" => "remote only\n"})
    commit_all(peer, "remote tree")
    git!(peer, ["push", "origin", "HEAD:refs/heads/remote-only"])
    git!(repo, ["fetch", "origin"])
    remote_tree = peer |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    unreachable = String.duplicate("f", 40)

    for {tree_hash, stamp} <- [{local_tree, "10"}, {remote_tree, "20"}, {unreachable, "30"}] do
      entry = Entry.build(tree_hash, %{}, run_at: stamp, run_id: stamp, specled_version: "test")
      assert :ok = Store.record(repo, entry)
    end

    assert {:ok, _} = Sync.run(repo)
    assert evidence_ids(repo) == Enum.sort([local_tree, remote_tree, unreachable])

    assert :ok = Mix.Tasks.Spec.Prune.run(["--root", repo])
    assert evidence_ids(repo) == Enum.sort([local_tree, remote_tree])
  end

  @tag spec: ["specled.tasks.prune_evidence", "specled.evidence_store.sync_entry_tolerance"]
  test "task surfaces a quarantine warning without raising or changing exit status", %{
    root: root
  } do
    %{repo: repo} = fixture!(root)
    reachable = repo |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    entry = Entry.build(reachable, %{}, run_at: "10", run_id: "10", specled_version: "test")
    assert :ok = Store.record(repo, entry)
    inject_raw_entry(repo, "notes.txt", "not an evidence entry\n")

    assert :ok = Mix.Tasks.Spec.Prune.run(["--root", repo])
    messages = drain_shell_messages()

    assert message_contains?(messages, "spec-evidence pruned and synced as of last fetch")
    assert message_contains?(messages, "evidence/entry_quarantined")
    assert message_contains?(messages, "notes.txt")
    assert reachable in evidence_ids(repo)
  end

  @tag spec: "specled.evidence_store.prune_reachability_floor"
  test "prune refuses when the reachable keep-set is empty instead of wiping the store", %{
    root: root
  } do
    %{repo: repo} = fixture!(root)
    reachable = repo |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    entry = Entry.build(reachable, %{}, run_at: "10", run_id: "10", specled_version: "test")
    assert :ok = Store.record(repo, entry)
    assert {:ok, _} = Sync.run(repo)

    drop_non_evidence_refs(repo)

    assert_raise Mix.Error, ~r/evidence\/prune_refused/, fn ->
      Mix.Tasks.Spec.Prune.run(["--root", repo])
    end

    assert reachable in evidence_ids(repo)
  end

  @tag spec: "specled.evidence_store.prune_reachability_floor"
  test "prune refuses when the keep-set matches none of the stored entries", %{root: root} do
    %{repo: repo} = fixture!(root)
    unreachable = String.duplicate("f", 40)

    entry = Entry.build(unreachable, %{}, run_at: "10", run_id: "10", specled_version: "test")
    assert :ok = Store.record(repo, entry)
    assert {:ok, _} = Sync.run(repo)

    assert_raise Mix.Error, ~r/evidence\/prune_refused/, fn ->
      Mix.Tasks.Spec.Prune.run(["--root", repo])
    end

    assert unreachable in evidence_ids(repo)
  end

  defp fixture!(root) do
    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    peer = Path.join(root, "peer")
    git!(root, ["init", "--bare", origin])
    File.mkdir_p!(repo)
    init_git_repo(repo)
    write_files(repo, %{"README.md" => "fixture\n"})
    commit_all(repo, "initial")
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-u", "origin", "main"])
    git!(root, ["clone", origin, peer])
    git!(peer, ["config", "user.name", "Spec Led Test"])
    git!(peer, ["config", "user.email", "specled@example.com"])
    %{repo: repo, peer: peer}
  end
end
