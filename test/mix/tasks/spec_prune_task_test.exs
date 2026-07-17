defmodule Mix.Tasks.SpecPruneTaskTest do
  use SpecLedEx.Case, async: false

  alias SpecLedEx.Evidence.{Entry, Store, Sync}

  @moduletag spec: [
               "specled.evidence_store.prune_explicit_only",
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

  defp evidence_ids(root) do
    root
    |> git!(["ls-tree", "--name-only", "refs/heads/spec-evidence"])
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.rootname(&1, ".json"))
    |> Enum.sort()
  end
end
