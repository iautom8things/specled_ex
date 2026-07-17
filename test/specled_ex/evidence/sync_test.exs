defmodule SpecLedEx.Evidence.SyncTest do
  use SpecLedEx.Case, async: false

  alias SpecLedEx.Evidence.{Entry, Store, Sync}

  @moduletag spec: [
               "specled.evidence_store.sync_tree_union",
               "specled.evidence_store.sync_failure_contracts",
               "specled.evidence_store.drift_surfaced"
             ]

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "remote-absent pushes and local-absent adopts without checking out the evidence ref", %{
    root: fixture_root
  } do
    %{a: a, b: b} = sync_fixture(fixture_root, "absence")
    assert :ok = Store.record(a, entry(hash("1"), "10", "a"))

    assert {:ok, %{action: :pushed, ahead: 1, behind: 0}} =
             Sync.run(a, sleep: fn _ -> :ok end)

    assert ref_absent?(b, "refs/heads/spec-evidence")
    assert {:ok, %{action: :adopted, ahead: 0, behind: 1}} = Sync.run(b)
    assert evidence_ids(b) == [hash("1")]
    refute current_branch(a) == "spec-evidence"
    refute current_branch(b) == "spec-evidence"
  end

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "tree union converges in both push orders and higher same-key stamp wins", %{
    root: fixture_root
  } do
    for {name, order} <- [{"a-first", [:a, :b]}, {"b-first", [:b, :a]}] do
      fixture = sync_fixture(fixture_root, name)
      seed_divergent_entries(fixture)

      Enum.each(order, fn clone ->
        assert {:ok, _result} = Sync.run(Map.fetch!(fixture, clone), sleep: fn _ -> :ok end)
      end)

      assert {:ok, _result} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
      assert evidence_ids(fixture.a) == Enum.sort([hash("1"), hash("2"), hash("3")])
      assert {:ok, winner} = Store.read(fixture.a, hash("3"))
      assert winner["run_id"] == "b"

      assert length(
               String.split(
                 git!(fixture.a, ["show", "-s", "--format=%P", "refs/heads/spec-evidence"])
               )
             ) == 2

      refute current_branch(fixture.a) == "spec-evidence"
      refute current_branch(fixture.b) == "spec-evidence"
    end
  end

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "lease rejection refetches, re-merges, and succeeds", %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "retry")
    assert :ok = Store.record(fixture.b, entry(hash("2"), "20", "b"))
    assert {:ok, _} = Sync.run(fixture.b)
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    before_push = fn _root, attempt, _fetched ->
      if attempt == 1 do
        assert :ok = Store.record(fixture.b, entry(hash("3"), "30", "c"))
        git!(fixture.b, ["push", "origin", "refs/heads/spec-evidence:refs/heads/spec-evidence"])
      end

      :ok
    end

    assert {:ok, %{attempts: 2}} =
             Sync.run(fixture.a, before_push: before_push, sleep: fn _ -> :ok end)

    assert evidence_ids(fixture.a) == Enum.sort([hash("1"), hash("2"), hash("3")])
  end

  @tag spec: "specled.evidence_store.sync_failure_contracts"
  test "three consecutive lease rejections exhaust the bounded retry", %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "exhaust")
    assert :ok = Store.record(fixture.b, entry(hash("2"), "20", "seed"))
    assert {:ok, _} = Sync.run(fixture.b)
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    before_push = fn _root, attempt, _fetched ->
      assert {:ok, _} = Sync.run(fixture.b, sleep: fn _ -> :ok end)

      assert :ok =
               Store.record(
                 fixture.b,
                 entry(hash(Integer.to_string(attempt + 3)), "3#{attempt}", "race")
               )

      git!(fixture.b, ["push", "origin", "refs/heads/spec-evidence:refs/heads/spec-evidence"])
      :ok
    end

    assert {:error, {:sync_exhausted, _reason}} =
             Sync.run(fixture.a, before_push: before_push, sleep: fn _ -> :ok end)
  end

  defp seed_divergent_entries(fixture) do
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))
    assert :ok = Store.record(fixture.a, entry(hash("3"), "20", "a"))
    assert :ok = Store.record(fixture.b, entry(hash("2"), "10", "b"))
    assert :ok = Store.record(fixture.b, entry(hash("3"), "20", "b"))
  end

  defp sync_fixture(root, name) do
    origin = Path.join(root, "#{name}-origin.git")
    seed = Path.join(root, "#{name}-seed")
    git!(root, ["init", "--bare", origin])
    File.mkdir_p!(seed)
    init_git_repo(seed)
    write_files(seed, %{"README.md" => "fixture\n"})
    commit_all(seed, "initial")
    git!(seed, ["remote", "add", "origin", origin])
    git!(seed, ["push", "-u", "origin", "main"])

    %{
      origin: origin,
      a: clone!(origin, Path.join(root, "#{name}-a")),
      b: clone!(origin, Path.join(root, "#{name}-b"))
    }
  end

  defp clone!(origin, path) do
    git!(Path.dirname(path), ["clone", origin, path])
    git!(path, ["config", "user.name", "Spec Led Test"])
    git!(path, ["config", "user.email", "specled@example.com"])
    path
  end

  defp evidence_ids(root) do
    root
    |> git!(["ls-tree", "--name-only", "refs/heads/spec-evidence"])
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.rootname(&1, ".json"))
    |> Enum.sort()
  end

  defp current_branch(root), do: root |> git!(["branch", "--show-current"]) |> String.trim()

  defp ref_absent?(root, ref) do
    {_output, status} = System.cmd("git", ["-C", root, "rev-parse", "--verify", "--quiet", ref])
    status != 0
  end

  defp entry(tree_hash, run_at, run_id) do
    Entry.build(tree_hash, %{}, run_at: run_at, run_id: run_id, specled_version: "test")
  end

  defp hash(seed), do: seed |> String.pad_trailing(40, seed) |> binary_part(0, 40)
end
